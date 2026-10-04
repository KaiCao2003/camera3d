from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import types
from pathlib import Path

import numpy as np
import pandas as pd
import pytest
import SimpleITK as sitk
import tifffile
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import brainbuilder_worker as worker  # noqa: E402


def feature_image(shape: tuple[int, int] = (120, 160)) -> tuple[np.ndarray, np.ndarray]:
    yy, xx = np.indices(shape)
    mask = ((xx - 80) / 66) ** 2 + ((yy - 61) / 49) ** 2 <= 1
    image = np.zeros(shape, dtype=np.float32)
    image[mask] = 0.18 + 0.22 * xx[mask] / shape[1]
    image += 0.65 * np.exp(-((xx - 55) ** 2 + (yy - 48) ** 2) / 150.0)
    image += 0.48 * np.exp(-((xx - 104) ** 2 + (yy - 74) ** 2) / 95.0)
    image += 0.30 * np.exp(-((xx - 92) ** 2 + (yy - 38) ** 2) / 45.0)
    return np.clip(image, 0, 1), mask


def save_rgba(path: Path, gray: np.ndarray, alpha: np.ndarray) -> None:
    value = (np.clip(gray, 0, 1) * 255).astype(np.uint8)
    rgba = np.stack([value, value, value, alpha.astype(np.uint8) * 255], axis=-1)
    Image.fromarray(rgba, mode="RGBA").save(path)


def minimal_slice(slice_id: str, source: Path, pixel_size: float = 25.0) -> dict:
    pose = {
        "atlasAPMicrons": 50.0,
        "atlasSlicingAngles": {
            "pitchDegrees": 0.0,
            "rollDegrees": 0.0,
            "yawDegrees": 0.0,
        },
        "rotationDegrees": 0.0,
        "flipHorizontal": False,
        "flipVertical": False,
        "sourceConfidence": 0.8,
        "manuallyLocked": False,
        "provenance": "synthetic",
    }
    return {
        "id": slice_id,
        "title": slice_id,
        "groupID": "XY01",
        "sourceImagePath": str(source),
        "pixelSizeMicrons": pixel_size,
        "imageSize": {"width": 160, "height": 120},
        "status": "poseEstimated",
        "pose": pose,
        "transformChain": {
            "direction": "atlasToSlice",
            "transforms": [worker.pose_transform(pose)],
        },
        "qc": {"warnings": []},
        "reviewNotes": "",
    }


def minimal_project(slices: list[dict], fixture: Path | None = None) -> dict:
    payload = {
        "id": "synthetic-project",
        "datasetRootPath": "/synthetic",
        "atlas": {
            "id": worker.ATLAS_NAME,
            "version": worker.ATLAS_VERSION,
            "name": "fixture",
            "voxelSizeMicrons": 25.0,
        },
        "orientation": "coronal",
        "pixelSizeMicrons": 25.0,
        "channelMappings": [
            {
                "channelIndex": 2,
                "name": "structural",
                "role": "structural",
                "pseudoColor": "Red",
            },
            {
                "channelIndex": 3,
                "name": "probe",
                "role": "probeTrack",
                "pseudoColor": "Green",
            },
        ],
        "slices": slices,
        "createdAt": worker.utc_now(),
        "updatedAt": worker.utc_now(),
        "sourceMode": "montageSections",
    }
    if fixture is not None:
        payload["atlasAssets"] = {"fixturePath": str(fixture)}
    return payload


@pytest.mark.parametrize("schema_version", [1, 2])
def test_read_json_rejects_tampered_project_with_more_than_32_track_candidates(
    tmp_path: Path,
    schema_version: int,
) -> None:
    source = tmp_path / "source.png"
    slice_record = minimal_slice("slice-overflow", source)
    slice_record["probeTrackCandidates"] = [
        {"candidateId": f"candidate-{index}"} for index in range(33)
    ]
    project = minimal_project([slice_record])
    project["schemaVersion"] = schema_version
    project_path = tmp_path / f"tampered-schema-{schema_version}.json"
    worker.write_json(project_path, project)

    with pytest.raises(worker.WorkerBlocked, match="32"):
        worker.read_json(project_path)


def test_reconstruction_rejects_loaded_project_with_more_than_32_track_candidates() -> (
    None
):
    project = minimal_project([])
    project["slices"] = [
        {
            "id": "slice-overflow",
            "status": "accepted",
            "probeTrackCandidates": [
                {"candidateId": f"candidate-{index}"} for index in range(33)
            ],
        }
    ]

    with pytest.raises(worker.WorkerBlocked, match="32-candidate"):
        worker.accepted_track_points(project)


def test_plan_roi_colony_and_ui_state_are_excluded_from_blind_registration_digest() -> (
    None
):
    project = minimal_project([])
    baseline = worker.blind_registration_input_sha256(project)
    project["colonySubjectReceipt"] = {
        "schemaVersion": 1,
        "service": "mouse_line",
        "publicId": "ML-2026-0001",
        "queryIdentifier": "ML-2026-0001",
        "matchedBy": "publicId",
        "subjectRecordSha256": "a" * 64,
        "verifiedAt": "2026-08-01T12:00:00Z",
        "sshHost": "hhw9l84",
        "sshRemotePort": 3004,
        "usableForNavigation": False,
    }
    with_receipt = worker.blind_registration_input_sha256(project)
    project["colonySubjectReceipt"]["subjectRecordSha256"] = "b" * 64
    project["subjectID"] = "ML-2026-0001"
    project["updatedAt"] = "2099-01-01T00:00:00Z"
    project["blindReviewLocked"] = True
    project["brain3dReview"] = {"suggestion": "must never enter blind input"}
    project["brain3dContext"] = {
        "blindReviewLocked": True,
        "handoff": {
            "handoff_id": "plan-a",
            "roi_sets": [{"roi_set_id": "roi-a"}],
            "insertion_snapshots": [{"insertion_snapshot_id": "insertion-a"}],
        },
    }
    project["blindTrackReview"] = {"assignments": ["post-reconstruction-only"]}
    project["blindTrackReviewPreview"] = {"tracks": ["preview-only"]}

    assert with_receipt == baseline
    assert worker.blind_registration_input_sha256(project) == baseline

    project["brain3dContext"]["handoff"] = {
        "handoff_id": "plan-b",
        "roi_sets": [{"roi_set_id": "completely-different-roi"}],
        "insertion_snapshots": [{"insertion_snapshot_id": "insertion-b"}],
    }
    assert worker.blind_registration_input_sha256(project) == baseline

    project["orientation"] = "sagittal"
    assert worker.blind_registration_input_sha256(project) != baseline


def test_register_project_emits_atomic_real_slice_progress(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source = tmp_path / "source.png"
    Image.new("L", (10, 10), 128).save(source)
    slices = [minimal_slice("slice-a", source), minimal_slice("slice-b", source)]
    project_path = tmp_path / "project.json"
    worker.write_json(project_path, minimal_project(slices))
    progress_path = tmp_path / "progress.json"
    observed: list[dict] = []
    original_atomic_write = worker.write_json_atomic

    def capture_atomic_write(path: Path, payload: dict) -> None:
        observed.append(json.loads(json.dumps(payload)))
        original_atomic_write(path, payload)

    def register_slice(
        project: dict,
        slice_record: dict,
        stage: str,
        out: Path,
        atlas: object,
        config: object,
    ) -> dict:
        if slice_record["id"] == "slice-b":
            raise worker.WorkerBlocked("synthetic failure")
        slice_record["status"] = "affineDone"
        return slice_record

    monkeypatch.setattr(worker, "write_json_atomic", capture_atomic_write)
    monkeypatch.setattr(
        worker,
        "load_atlas",
        lambda project, annotations: types.SimpleNamespace(name="fixture"),
    )
    monkeypatch.setattr(worker, "register_one_slice", register_slice)

    result = worker.command_register_project(
        argparse.Namespace(
            command="register-project",
            project=project_path,
            stage="affine",
            out=tmp_path / "out",
            progress_json=progress_path,
        )
    )

    registering = [item for item in observed if item["stage"] == "registeringSlices"]
    assert [
        (item["completed"], item["sliceID"], item["failed"]) for item in registering
    ] == [
        (0, "slice-a", 0),
        (1, "slice-a", 0),
        (1, "slice-b", 0),
        (2, "slice-b", 1),
    ]
    assert observed[-2]["stage"] == "finalizing"
    assert observed[-1]["stage"] == "completed"
    assert observed[-1]["completed"] == observed[-1]["total"] == 2
    assert observed[-1]["failed"] == 1
    assert json.loads(progress_path.read_text(encoding="utf-8")) == observed[-1]
    assert result["stage"] == "ok"
    assert result["project"]["slices"][1]["status"] == "failed"


def test_prepare_rejects_duplicate_logical_rasters(tmp_path: Path) -> None:
    gray, mask = feature_image()
    image_path = tmp_path / "section.png"
    save_rgba(image_path, gray, mask)
    project = minimal_project(
        [minimal_slice("slice-a", image_path), minimal_slice("slice-b", image_path)]
    )

    with pytest.raises(worker.WorkerBlocked, match="share the same raster"):
        worker.prepare_project(project, tmp_path / "prepared")


def test_prepared_alpha_domain_excludes_brighter_neighbor(tmp_path: Path) -> None:
    height, width = 90, 150
    yy, xx = np.indices((height, width))
    selected = ((xx - 42) / 32) ** 2 + ((yy - 45) / 35) ** 2 <= 1
    neighbor = ((xx - 112) / 30) ** 2 + ((yy - 45) / 34) ** 2 <= 1
    gray = np.zeros((height, width), dtype=np.float32)
    gray[selected] = 0.35
    gray[neighbor] = 0.95
    path = tmp_path / "masked-structural.png"
    save_rgba(path, gray, selected)

    prepared = worker.load_prepared_image(path)

    assert not np.any(prepared.mask & ~selected)
    assert worker.dice_score(prepared.mask, selected) >= 0.99
    assert not np.any(prepared.mask & neighbor)


def test_empty_prepared_alpha_domain_fails_closed(tmp_path: Path) -> None:
    gray = np.linspace(0.0, 1.0, 80 * 60, dtype=np.float32).reshape(60, 80)
    path = tmp_path / "empty-selected-section.png"
    save_rgba(path, gray, np.zeros_like(gray, dtype=bool))

    with pytest.raises(worker.WorkerBlocked, match="alpha mask is empty"):
        worker.load_prepared_image(path)


@pytest.mark.parametrize(
    ("extra_mapping", "message"),
    [
        (
            {"channelIndex": 4, "name": "structural-2", "role": "structural"},
            "exactly one structural",
        ),
        (
            {"channelIndex": 4, "name": "probe-2", "role": "probeTrack"},
            "at most one probe-track",
        ),
    ],
)
def test_prepare_rejects_ambiguous_registration_channels(
    tmp_path: Path, extra_mapping: dict, message: str
) -> None:
    gray, mask = feature_image()
    image_path = tmp_path / "section.png"
    save_rgba(image_path, gray, mask)
    project = minimal_project([minimal_slice("slice", image_path)])
    project["channelMappings"].append(extra_mapping)

    with pytest.raises(worker.WorkerBlocked, match=message):
        worker.prepare_project(project, tmp_path / "prepared")


def test_export_blockers_reject_ambiguous_registration_channels() -> None:
    project = minimal_project([])
    project["channelMappings"].append(
        {"channelIndex": 4, "name": "structural-2", "role": "structural"}
    )
    assert any(
        "exactly one structural" in blocker
        for blocker in worker.project_blockers(project)
    )

    project["channelMappings"].pop()
    project["channelMappings"].append(
        {"channelIndex": 4, "name": "probe-2", "role": "probeTrack"}
    )
    assert any("at most one" in blocker for blocker in worker.project_blockers(project))


def test_affine_direction_recovers_known_transform() -> None:
    image, mask = feature_image()
    spacing = 25.0
    fixed = worker.moving_sitk(image, spacing)
    fixed_mask = worker.moving_sitk(
        mask.astype(np.uint8), spacing, pixel_id=sitk.sitkUInt8
    )
    true_transform = sitk.AffineTransform(2)
    angle = np.deg2rad(1.5)
    true_transform.SetMatrix(
        (np.cos(angle), -np.sin(angle), np.sin(angle), np.cos(angle))
    )
    true_transform.SetCenter((80 * spacing, 60 * spacing))
    true_transform.SetTranslation((25.0, -20.0))
    moving = sitk.Resample(
        fixed,
        fixed,
        true_transform.GetInverse(),
        sitk.sitkLinear,
        0.0,
        sitk.sitkFloat32,
    )
    moving_mask = sitk.Resample(
        fixed_mask,
        fixed_mask,
        true_transform.GetInverse(),
        sitk.sitkNearestNeighbor,
        0,
        sitk.sitkUInt8,
    )

    result, _, _ = worker.register_affine(
        fixed,
        moving,
        worker.RegistrationConfig(iterations=90, sampling_percentage=0.75),
        fixed_mask=fixed_mask,
        moving_mask=moving_mask,
    )
    points = [(800.0, 750.0), (2_000.0, 600.0), (1_100.0, 2_000.0), (2_700.0, 2_200.0)]
    errors = [
        np.linalg.norm(
            np.asarray(result.TransformPoint(point))
            - np.asarray(true_transform.TransformPoint(point))
        )
        for point in points
    ]
    registered_mask = (
        sitk.GetArrayFromImage(
            sitk.Resample(
                moving_mask,
                fixed_mask,
                result,
                sitk.sitkNearestNeighbor,
                0,
                sitk.sitkUInt8,
            )
        )
        > 0
    )

    assert float(np.sqrt(np.mean(np.square(errors)))) < 8.0
    assert worker.dice_score(registered_mask, mask) > 0.97


def test_materially_degrading_affine_keeps_better_initializer() -> None:
    initial = sitk.AffineTransform(2)
    optimized = sitk.AffineTransform(2)
    optimized.SetTranslation((120.0, -80.0))

    selected, selected_iou, rejected = worker.non_degrading_affine_result(
        initial,
        optimized,
        initial_iou=0.86,
        optimized_iou=0.81,
    )

    assert rejected
    assert selected_iou == pytest.approx(0.86)
    assert worker.affine_json(selected) == worker.affine_json(initial)

    selected, selected_iou, rejected = worker.non_degrading_affine_result(
        initial,
        optimized,
        initial_iou=0.86,
        optimized_iou=0.855,
    )
    assert not rejected
    assert selected_iou == pytest.approx(0.855)
    assert worker.affine_json(selected) == worker.affine_json(optimized)


def test_quicknii_ras_coordinates_are_flipped_into_brainglobe_asr() -> None:
    shape = (528, 320, 456)
    origin = worker.quicknii_ras_to_brainglobe_asr(np.asarray([0.0, 0.0, 0.0]), shape)
    opposite = worker.quicknii_ras_to_brainglobe_asr(
        np.asarray([455.0, 527.0, 319.0]), shape
    )
    vector = worker.quicknii_ras_vector_to_brainglobe_asr(np.asarray([1.0, 2.0, 3.0]))

    assert np.array_equal(origin, np.asarray([527.0, 319.0, 455.0]))
    assert np.array_equal(opposite, np.zeros(3))
    assert np.array_equal(vector, np.asarray([-2.0, -3.0, -1.0]))


def test_install_pose_invalidates_registration_and_track_outputs(
    tmp_path: Path,
) -> None:
    source = tmp_path / "source.png"
    Image.new("RGB", (40, 32), "white").save(source)
    slice_record = minimal_slice("rerun", source)
    slice_record["status"] = "accepted"
    slice_record["transformChain"]["transforms"].append(
        {"kind": "affine", "transformParametersPath": "/stale/affine.tfm"}
    )
    slice_record["artifacts"] = {
        "annotationImagePath": "/stale/annotation.tif",
        "boundaryImagePath": "/stale/boundary.png",
        "transformPath": "/stale/affine.tfm",
        "structuralImagePath": str(source),
    }
    slice_record["probeTrack"] = {"status": "atlasMapped", "reviewAccepted": True}
    slice_record["qc"] = {
        "warnings": [],
        "majorRegionIoU": 0.9,
        "mutualInformationMetric": -1.2,
    }
    new_pose = dict(slice_record["pose"])
    new_pose["atlasAPMicrons"] = 75.0

    worker.install_pose(slice_record, new_pose, engine="test pose")

    assert slice_record["status"] == "poseEstimated"
    assert [item["kind"] for item in slice_record["transformChain"]["transforms"]] == [
        "pose"
    ]
    assert slice_record["artifacts"]["annotationImagePath"] is None
    assert slice_record["artifacts"]["boundaryImagePath"] is None
    assert slice_record["artifacts"]["transformPath"] is None
    assert slice_record["artifacts"]["structuralImagePath"] == str(source)
    assert slice_record["probeTrack"] is None
    assert slice_record["qc"]["majorRegionIoU"] is None
    assert slice_record["qc"]["mutualInformationMetric"] is None


def test_group_orientation_selector_uses_upright_anatomy_and_serial_continuity() -> (
    None
):
    slices = [
        {"id": "A-montage-0", "groupID": "A"},
        {"id": "A-montage-1", "groupID": "A"},
        {"id": "B-montage-0", "groupID": "B"},
        {"id": "B-montage-1", "groupID": "B"},
        {"id": "C-montage-0", "groupID": "C"},
        {"id": "C-montage-1", "groupID": "C"},
    ]
    depths = {
        ("A-montage-0", 0): 90.0,
        ("A-montage-1", 0): 88.0,
        ("A-montage-0", 180): 52.0,
        ("A-montage-1", 180): 50.0,
        ("B-montage-0", 0): 80.0,
        ("B-montage-1", 0): 78.0,
        ("B-montage-0", 180): 47.0,
        ("B-montage-1", 180): 45.0,
        ("C-montage-0", 0): 42.0,
        ("C-montage-1", 0): 40.0,
        ("C-montage-0", 180): 70.0,
        ("C-montage-1", 180): 68.0,
    }
    upright = {
        (slice_record["id"], rotation): (
            0.20 if (slice_record["groupID"] != "C") == (rotation == 0) else -0.20
        )
        for slice_record in slices
        for rotation in (0, 180)
    }

    first = worker.select_group_orientations(slices, depths, upright)
    second = worker.select_group_orientations(slices, depths, upright)

    assert first == {"A": 0, "B": 0, "C": 180}
    assert second == first


def test_materialized_orientation_keeps_structural_probe_overlay_and_mask_aligned(
    tmp_path: Path,
) -> None:
    height, width = 36, 48
    mask = np.zeros((height, width), dtype=bool)
    mask[4:14, 5:43] = True
    mask[14:31, 13:35] = True
    gray = mask.astype(np.float32) * 0.35
    structural = tmp_path / "structural.png"
    probe = tmp_path / "probe.png"
    source_overlay = tmp_path / "source-overlay.png"
    save_rgba(structural, gray, mask)
    save_rgba(probe, gray * 0.5, mask)
    save_rgba(source_overlay, gray * 0.8, mask)
    for path, color_value in ((structural, 80), (probe, 160), (source_overlay, 240)):
        with Image.open(path) as image:
            rgba = np.asarray(image.convert("RGBA")).copy()
        rgba[6, 9, :3] = color_value
        Image.fromarray(rgba, mode="RGBA").save(path)

    slice_record = minimal_slice("oriented", structural)
    slice_record["pose"]["rotationDegrees"] = 180.0
    slice_record["artifacts"] = {
        "structuralImagePath": str(structural),
        "probeChannelImagePath": str(probe),
        "sourceOverlayImagePath": str(source_overlay),
    }
    prepared = worker.load_prepared_image(structural, slice_record["pose"])
    worker.materialize_oriented_source_artifacts(
        slice_record, prepared, tmp_path / "canonical"
    )
    artifacts = slice_record["artifacts"]
    expected_y, expected_x = height - 1 - 6, width - 1 - 9

    for key, color_value in (
        ("structuralImagePath", 80),
        ("probeChannelImagePath", 160),
        ("sourceOverlayImagePath", 240),
    ):
        with Image.open(artifacts[key]) as image:
            rgba = np.asarray(image.convert("RGBA"))
        assert int(rgba[expected_y, expected_x, 0]) == color_value
        assert int(rgba[6, 9, 0]) != color_value

    saved_mask = np.asarray(Image.open(artifacts["tissueMaskPath"])) > 0
    assert np.array_equal(saved_mask, prepared.mask)
    assert artifacts["rawStructuralImagePath"] == str(structural.resolve())
    assert artifacts["rawProbeChannelImagePath"] == str(probe.resolve())
    assert artifacts["rawSourceOverlayImagePath"] == str(source_overlay.resolve())
    assert slice_record["sourceImagePath"] == str(structural)
    assert (
        worker.pose_transform(slice_record["pose"])["rasterOrientation"][
            "rotationDegrees"
        ]
        == 180
    )


def test_deepslice_selects_group_orientation_then_enforces_order_before_angles(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    mask = np.zeros((48, 64), dtype=bool)
    mask[5:18, 6:58] = True
    mask[18:42, 17:47] = True
    gray = mask.astype(np.float32) * 0.55
    slices: list[dict] = []
    for index, group in enumerate(("A", "A", "B", "B")):
        path = tmp_path / f"section-{index}.png"
        if group == "A":
            save_rgba(path, gray, mask)
        else:
            save_rgba(path, np.rot90(gray, 2), np.rot90(mask, 2))
        slice_record = minimal_slice(f"{group}-montage-{index % 2}", path)
        slice_record["groupID"] = group
        slices.append(slice_record)

    depth_by_source_and_rotation = {
        (0, 0): 90.0,
        (1, 0): 88.0,
        (0, 180): 52.0,
        (1, 180): 50.0,
        (2, 0): 45.0,
        (3, 0): 43.0,
        (2, 180): 80.0,
        (3, 180): 78.0,
    }
    events: list[tuple] = []

    class FakeDSModel:
        def __init__(self, species: str) -> None:
            assert species == "mouse"
            self.predictions = pd.DataFrame()

        def predict(
            self, image_directory: str, ensemble: bool, section_numbers: bool
        ) -> None:
            assert ensemble
            assert section_numbers
            rows = []
            candidates = sorted(
                Path(image_directory).glob("*.png"),
                key=lambda path: int(re.search(r"_s(\d+)", path.name).group(1)),
            )
            events.append(("predict", len(candidates)))
            for path in candidates:
                candidate_number = int(re.search(r"_s(\d+)", path.name).group(1))
                source_index = (candidate_number - 1) // 2
                rotation = int(re.search(r"_r(\d+)", path.name).group(1))
                depth = depth_by_source_and_rotation[(source_index, rotation)]
                with Image.open(path) as image:
                    image_width, image_height = image.size
                rows.append(
                    {
                        "Filenames": str(path),
                        "nr": candidate_number,
                        "depth": depth,
                        "ox": 0.0,
                        "oy": depth,
                        "oz": 0.0,
                        "ux": 1.0,
                        "uy": 0.0,
                        "uz": 0.0,
                        "vx": 0.0,
                        "vy": 0.0,
                        "vz": 1.0,
                        "width": image_width,
                        "height": image_height,
                    }
                )
            self.predictions = pd.DataFrame(rows)

        def enforce_index_order(self) -> None:
            events.append(
                ("enforce", len(self.predictions), tuple(self.predictions["nr"]))
            )

        def propagate_angles(self) -> None:
            events.append(("propagate", len(self.predictions)))

    deepslice_module = types.ModuleType("DeepSlice")
    deepslice_module.__path__ = []
    deepslice_module.DSModel = FakeDSModel
    coordinate_module = types.ModuleType("DeepSlice.coord_post_processing")
    coordinate_module.__path__ = []
    depth_module = types.ModuleType("DeepSlice.coord_post_processing.depth_estimation")
    depth_module.calculate_brain_center_depths = lambda predictions: predictions[
        "depth"
    ].to_numpy()
    monkeypatch.setitem(sys.modules, "DeepSlice", deepslice_module)
    monkeypatch.setitem(
        sys.modules, "DeepSlice.coord_post_processing", coordinate_module
    )
    monkeypatch.setitem(
        sys.modules, "DeepSlice.coord_post_processing.depth_estimation", depth_module
    )

    atlas = worker.AtlasData(
        name="fixture",
        version="test",
        reference=np.zeros((128, 48, 64), dtype=np.uint16),
        annotation=np.ones((128, 48, 64), dtype=np.uint32),
        resolution=(25.0, 25.0, 25.0),
        orientation="asr",
        structures={},
        root_dir=tmp_path,
    )
    project = minimal_project(slices)
    output = tmp_path / "pose"
    result = worker.estimate_poses_with_deepslice(project, atlas, output)

    assert events == [
        ("predict", 8),
        ("enforce", 4, (1, 2, 3, 4)),
        ("propagate", 4),
        ("enforce", 4, (1, 2, 3, 4)),
    ]
    assert [item["pose"]["rotationDegrees"] for item in result["slices"]] == [
        0.0,
        0.0,
        180.0,
        180.0,
    ]
    assert result["provenance"]["deepSliceGroupOrientations"] == {"A": 0, "B": 180}
    assert result["provenance"]["deepSliceIndexOrderEnforced"] is True
    assert result["provenance"]["deepSliceIndexOrderRecheckedAfterAngles"] is True
    assert result["provenance"]["deepSliceBrainCenterOrderCorrected"] is True
    for item in result["slices"]:
        assert item["qc"]["rawPoseAPMicrons"] == pytest.approx(item["pose"]["atlasAPMicrons"])
        assert item["qc"]["orderedPoseAPMicrons"] == pytest.approx(item["pose"]["atlasAPMicrons"])
        assert item["qc"]["poseAdjustmentMicrons"] == pytest.approx(0)
    with (output / "deepslice-predictions.csv").open(
        newline="", encoding="utf-8"
    ) as handle:
        assert len(list(csv.DictReader(handle))) == 4
    with (output / "deepslice-orientation-candidates.csv").open(
        newline="", encoding="utf-8"
    ) as handle:
        candidates = list(csv.DictReader(handle))
    assert len(candidates) == 8
    assert sum(row["selected"] == "True" for row in candidates) == 4


def test_affine_record_requires_a_parseable_matching_transform(tmp_path: Path) -> None:
    invalid_path = tmp_path / "not-a-transform.tfm"
    invalid_path.write_text("placeholder", encoding="utf-8")
    record = {
        "kind": "affine",
        "direction": "atlasToSlice",
        "coordinateUnit": "micron",
        "affine": {"m00": 1, "m01": 0, "m10": 0, "m11": 1, "tx": 0, "ty": 0},
        "transformParametersPath": str(invalid_path),
    }
    assert not worker.valid_affine_transform_record(record)

    valid_path = tmp_path / "identity.tfm"
    sitk.WriteTransform(sitk.AffineTransform(2), str(valid_path))
    record["transformParametersPath"] = str(valid_path)
    record["affine"]["tx"] = 10
    assert not worker.valid_affine_transform_record(record)
    record["affine"]["tx"] = 0
    assert worker.valid_affine_transform_record(record)


def test_probe_requires_channel_and_recovers_continuous_bright_track(
    tmp_path: Path,
) -> None:
    structural, mask = feature_image()
    structural_path = tmp_path / "structural.png"
    probe_path = tmp_path / "probe.png"
    save_rgba(structural_path, structural, mask)
    probe = structural * 0.42
    intended_points: list[tuple[int, int]] = []
    for y in range(24, 104):
        x = int(round(68 + 0.22 * y))
        intended_points.append((x, y))
        probe[max(0, y - 1) : y + 2, max(0, x - 1) : x + 2] += 0.48 + 0.22 * (y / 104)
    # Dim crack-like distractor: longer than many track fragments but much weaker.
    for x in range(112, 148):
        y = 38 + (x - 112) // 3
        probe[y : y + 2, x : x + 2] += 0.10
    save_rgba(probe_path, np.clip(probe, 0, 1), mask)
    prepared = worker.load_prepared_image(structural_path)
    slice_record = minimal_slice("track", structural_path, pixel_size=10.0)

    missing = worker.detect_probe_track(slice_record, prepared, tmp_path / "missing")
    assert missing["status"] == "noTrack"
    assert missing["points"] == []

    slice_record["artifacts"] = {
        "structuralImagePath": str(structural_path),
        "probeChannelImagePath": str(probe_path),
    }
    detection = worker.detect_probe_track(slice_record, prepared, tmp_path / "detected")
    start = np.asarray([detection["lineStart"]["x"], detection["lineStart"]["y"]])
    end = np.asarray([detection["lineEnd"]["x"], detection["lineEnd"]["y"]])
    intended_span = np.linalg.norm(np.subtract(intended_points[-1], intended_points[0]))

    assert np.linalg.norm(end - start) / intended_span >= 0.70
    assert sum(point.get("inlier", False) for point in detection["points"]) >= 20
    assert detection["confidence"] >= 0.65


def test_fallback_pose_registration_is_always_review_gated(tmp_path: Path) -> None:
    gray, mask = feature_image()
    source = tmp_path / "section.png"
    save_rgba(source, gray, mask)
    reference = np.repeat((gray * 65535).astype(np.uint16)[None, ...], 5, axis=0)
    annotation = np.repeat((mask.astype(np.uint32) * 42)[None, ...], 5, axis=0)
    atlas = worker.AtlasData(
        name="fixture",
        version="test",
        reference=reference,
        annotation=annotation,
        resolution=(25.0, 25.0, 25.0),
        orientation="asr",
        structures={
            42: {"id": 42, "acronym": "T", "name": "Test", "rgb_triplet": [1, 2, 3]}
        },
        root_dir=tmp_path,
    )
    slice_record = minimal_slice("fallback", source)
    slice_record["artifacts"] = {"structuralImagePath": str(source)}
    project = minimal_project([slice_record])
    project["provenance"] = {"poseEngine": "BrainGlobe annotation silhouette fallback"}

    worker.register_one_slice(
        project,
        slice_record,
        "affine",
        tmp_path / "registered",
        atlas,
        worker.RegistrationConfig(iterations=10, sampling_percentage=0.75),
    )

    assert slice_record["status"] == "needsReview"
    assert any(
        "silhouette fallback" in warning for warning in slice_record["qc"]["warnings"]
    )


def test_probe_trajectory_requires_explicit_review_on_two_distinct_slices(
    tmp_path: Path,
) -> None:
    annotation = np.full((20, 20, 20), 42, dtype=np.uint32)
    atlas = worker.AtlasData(
        name="fixture",
        version="test",
        reference=np.zeros_like(annotation, dtype=np.uint16),
        annotation=annotation,
        resolution=(25.0, 25.0, 25.0),
        orientation="asr",
        structures={
            42: {"id": 42, "acronym": "T", "name": "Test", "rgb_triplet": [1, 2, 3]}
        },
        root_dir=tmp_path,
    )

    def track_slice(slice_id: str, reviewed: bool, offset: float) -> dict:
        return {
            "id": slice_id,
            "status": "accepted",
            "probeTrack": {
                "reviewAccepted": reviewed,
                "atlasPoints": [
                    {
                        "apMicrons": 50.0 + offset + index * 20.0,
                        "dorsalVentralMicrons": 100.0 + index * 10.0,
                        "rightLeftMicrons": 150.0 + index * 5.0,
                    }
                    for index in range(3)
                ],
            },
        }

    project = {"slices": [track_slice("one", True, 0), track_slice("two", False, 10)]}
    output = tmp_path / "track"
    output.mkdir()
    assert worker.reconstruct_probe_track(project, atlas, output) == (None, None)

    project["slices"][1]["probeTrack"]["reviewAccepted"] = True
    track_path, sites_path = worker.reconstruct_probe_track(project, atlas, output)
    assert track_path == "probe-track.json"
    assert sites_path == "trajectory-samples.csv"
    track = json.loads((output / track_path).read_text(encoding="utf-8"))
    assert track["distinctSliceCount"] == 2


def test_blind_reconstruction_extracts_multiple_tracks_with_exclusive_membership(
    tmp_path: Path,
) -> None:
    annotation = np.full((80, 80, 80), 42, dtype=np.uint32)
    atlas = worker.AtlasData(
        name=worker.ATLAS_NAME,
        version=worker.ATLAS_VERSION,
        reference=np.zeros_like(annotation, dtype=np.uint16),
        annotation=annotation,
        resolution=(25.0, 25.0, 25.0),
        orientation="asr",
        structures={
            42: {"id": 42, "acronym": "T", "name": "Test", "rgb_triplet": [1, 2, 3]}
        },
        root_dir=tmp_path,
    )

    def candidate(candidate_id: str, ml_offset: float, slice_offset: float) -> dict:
        return {
            "candidateId": candidate_id,
            "reviewAccepted": True,
            "atlasPoints": [
                {
                    "slicePoint": {"x": float(index), "y": float(index + 1)},
                    "apMicrons": 200.0 + slice_offset + index * 40.0,
                    "dorsalVentralMicrons": 300.0 + index * 60.0,
                    "rightLeftMicrons": ml_offset + index * 8.0,
                }
                for index in range(4)
            ],
            "points": [
                {
                    "pointId": f"{candidate_id}-point-{index}",
                    "x": float(index),
                    "y": float(index + 1),
                    "inlier": True,
                }
                for index in range(4)
            ],
        }

    project = {
        "slices": [
            {
                "id": "slice-a",
                "status": "accepted",
                "probeTrackCandidates": [
                    candidate("a-one", 250.0, 0.0),
                    candidate("a-two", 900.0, 0.0),
                ],
            },
            {
                "id": "slice-b",
                "status": "accepted",
                "probeTrackCandidates": [
                    candidate("b-one", 250.0, 12.0),
                    candidate("b-two", 900.0, 12.0),
                ],
            },
            {
                "id": "slice-c",
                "status": "accepted",
                "probeTrackCandidates": [
                    candidate("c-one", 250.0, 24.0),
                    candidate("c-two", 900.0, 24.0),
                ],
            },
        ]
    }
    output = tmp_path / "multi-track"
    output.mkdir()
    tracks_path, samples_path = worker.reconstruct_probe_tracks(project, atlas, output)
    document = json.loads((output / tracks_path).read_text(encoding="utf-8"))

    assert document["schemaVersion"] == 2
    assert document["coordinateOrder"] == ["AP", "DV", "ML"]
    assert len(document["tracks"]) == 2
    source_ids = [
        point["sourcePointID"]
        for track in document["tracks"]
        for point in track["sourcePoints"]
    ]
    assert len(source_ids) == len(set(source_ids)) == 24
    assert all(track["usableForNavigation"] is False for track in document["tracks"])
    assert all(
        track["leaveOneSectionOutSensitivity"]["available"] is True
        and track["leaveOneSectionOutSensitivity"]["omissionCount"] == 3
        and track["leaveOneSectionOutSensitivity"]["usableForNavigation"] is False
        for track in document["tracks"]
    )
    assert samples_path == "trajectory-samples.csv"


def test_leave_one_section_out_sensitivity_is_deterministic_and_requires_three_sections() -> (
    None
):
    points = np.asarray(
        [
            [0.0, 0.0, 0.0],
            [0.0, 100.0, 0.0],
            [0.0, 200.0, 0.0],
            [0.0, 300.0, 0.0],
            [0.0, 400.0, 0.0],
            [0.0, 500.0, 0.0],
        ],
        dtype=np.float64,
    )
    records = [
        {"sliceID": slice_id, "sourcePointID": f"point-{index}"}
        for index, slice_id in enumerate(
            ("slice-c", "slice-c", "slice-a", "slice-a", "slice-b", "slice-b")
        )
    ]
    origin = points.mean(axis=0)
    direction = np.asarray([0.0, 1.0, 0.0])

    sensitivity = worker._leave_one_section_out_sensitivity(
        points,
        records,
        origin,
        direction,
    )

    assert sensitivity["available"] is True
    assert (
        sensitivity["method"] == "deterministic-pca-line-refit-leave-one-section-out-v1"
    )
    assert [item["omittedSliceId"] for item in sensitivity["omissions"]] == [
        "slice-a",
        "slice-b",
        "slice-c",
    ]
    assert sensitivity["maximumAxisAngleDegrees"] == pytest.approx(0.0, abs=1e-9)
    assert sensitivity["maximumLineSeparationMicrometres"] == pytest.approx(
        0.0, abs=1e-9
    )
    assert sensitivity["rmsHeldOutResidualMicrometres"] == pytest.approx(0.0, abs=1e-9)
    assert sensitivity["usableForNavigation"] is False
    assert sensitivity == worker._leave_one_section_out_sensitivity(
        points,
        records,
        origin,
        -direction,
    )

    unavailable = worker._leave_one_section_out_sensitivity(
        points[:4],
        records[:4],
        points[:4].mean(axis=0),
        direction,
    )
    assert unavailable == {
        "available": False,
        "reason": "requires at least 3 distinct accepted slices",
        "usableForNavigation": False,
    }

    invalid_points = points.copy()
    invalid_points[0, 0] = np.nan
    with pytest.raises(worker.WorkerBlocked, match="aligned finite ASR points"):
        worker._leave_one_section_out_sensitivity(
            invalid_points,
            records,
            origin,
            direction,
        )


def test_posthoc_matching_uses_asr_ml_without_laterality_flip() -> None:
    track = {
        "trackId": "observed",
        "endpointA": [100.0, 100.0, 700.0],
        "endpointB": [200.0, 1100.0, 800.0],
        "rmseMicrometres": 20.0,
    }
    candidate = {
        "insertionSnapshotId": "insertion-right",
        "planId": "plan-right",
        "planVersion": 1,
        "planInputSha256": "a" * 64,
        "shankId": "shank-0",
        "entry": np.asarray([100.0, 100.0, 700.0]),
        "tip": np.asarray([200.0, 1100.0, 800.0]),
    }
    metrics = worker.track_shank_metrics(track, candidate)
    assert metrics["axisAngleDegrees"] == pytest.approx(0.0, abs=1e-9)
    assert metrics["finiteSegmentDistanceMicrometres"] == pytest.approx(0.0, abs=1e-9)
    assert metrics["sameDV"]["mlRMSMicrometres"] == pytest.approx(0.0, abs=1e-9)
    assert metrics["eligibleForSuggestion"] is True


def test_brain3d_review_suggestions_require_blind_lock_and_reviewer_confirmation() -> (
    None
):
    tracks = {
        "tracks": [
            {
                "trackId": "observed",
                "endpointA": [100.0, 100.0, 700.0],
                "endpointB": [200.0, 1100.0, 800.0],
                "rmseMicrometres": 20.0,
            }
        ]
    }
    handoff = {
        "insertion_snapshots": [
            {
                "insertion_snapshot_id": "insertion-right",
                "plan_ref": {
                    "plan_id": "plan-right",
                    "plan_version": 1,
                    "plan_input_sha256": "a" * 64,
                },
                "planned_shanks": [
                    {
                        "shank_id": "shank-0",
                        "surface_entry": {
                            "ap_um": 100.0,
                            "dv_um": 100.0,
                            "ml_um": 700.0,
                        },
                        "tip": {"ap_um": 200.0, "dv_um": 1100.0, "ml_um": 800.0},
                    }
                ],
            }
        ]
    }
    unlocked = {"brain3dContext": {"blindReviewLocked": False, "handoff": handoff}}
    with pytest.raises(worker.WorkerBlocked, match="blind registration"):
        worker.build_brain3d_review(unlocked, tracks)

    locked = {
        "brain3dContext": {
            "blindReviewLocked": True,
            "handoff": handoff,
            "priorReceipt": {"handoffId": "handoff"},
            "reviewDispositions": [],
        }
    }
    review = worker.build_brain3d_review(locked, tracks, require_complete=False)
    assert review["policy"] == "brain3d-prior-posthoc-overlay-only-v1"
    assert review["suggestions"][0]["requiresReviewerConfirmation"] is True
    assert review["reviewDispositions"] == []
    assert review["usableForNavigation"] is False


def _manual_disposition(
    state: str,
    *,
    identifier: str,
    track_id: str | None = None,
    insertion_id: str | None = None,
    shank_id: str | None = None,
) -> dict:
    return {
        "id": identifier,
        "state": state,
        "trackId": track_id,
        "insertionSnapshotId": insertion_id,
        "shankId": shank_id,
        "reviewerLabel": "reviewer-a",
        "reason": "Manual post-hoc evidence review",
        "confirmedAt": "2026-08-01T20:00:00Z",
    }


def test_brain3d_review_requires_complete_manual_observed_and_planned_dispositions() -> (
    None
):
    handoff = {
        "insertion_snapshots": [
            {
                "insertion_snapshot_id": "insertion-1",
                "plan_ref": {
                    "plan_id": "plan-1",
                    "plan_version": 1,
                    "plan_input_sha256": "a" * 64,
                },
                "planned_shanks": [
                    {
                        "shank_id": "shank-0",
                        "surface_entry": {"ap_um": 0.0, "dv_um": 0.0, "ml_um": 0.0},
                        "tip": {"ap_um": 0.0, "dv_um": 1000.0, "ml_um": 0.0},
                    },
                    {
                        "shank_id": "shank-1",
                        "surface_entry": {"ap_um": 250.0, "dv_um": 0.0, "ml_um": 0.0},
                        "tip": {"ap_um": 250.0, "dv_um": 1000.0, "ml_um": 0.0},
                    },
                ],
            }
        ]
    }
    tracks = {
        "tracks": [
            {
                "trackId": "track-1",
                "endpointA": [0.0, 0.0, 0.0],
                "endpointB": [0.0, 1000.0, 0.0],
                "rmseMicrometres": 20.0,
            }
        ]
    }
    context = {
        "blindReviewLocked": True,
        "handoff": handoff,
        "priorReceipt": {"handoffId": "handoff"},
        "reviewDispositions": [],
    }
    with pytest.raises(worker.WorkerBlocked, match="observed track"):
        worker.build_brain3d_review({"brain3dContext": context}, tracks)

    context["reviewDispositions"] = [
        _manual_disposition(
            "exactShank",
            identifier="d1",
            track_id="track-1",
            insertion_id="insertion-1",
            shank_id="shank-0",
        )
    ]
    with pytest.raises(worker.WorkerBlocked, match="planned physical shank"):
        worker.build_brain3d_review({"brain3dContext": context}, tracks)

    context["reviewDispositions"].append(
        _manual_disposition(
            "plannedNotObserved",
            identifier="d2",
            insertion_id="insertion-1",
            shank_id="shank-1",
        )
    )
    review = worker.build_brain3d_review({"brain3dContext": context}, tracks)
    assert review["status"] == "reviewed"
    assert len(review["matrix"]) == 2
    assert len(review["reviewDispositions"]) == 2


def test_brain3d_insertion_ambiguity_covers_shanks_but_cannot_claim_them_missing() -> (
    None
):
    candidates = [
        {"insertionSnapshotId": "i", "shankId": "s0"},
        {"insertionSnapshotId": "i", "shankId": "s1"},
    ]
    tracks = [{"trackId": "t"}]
    context = {
        "reviewDispositions": [
            _manual_disposition(
                "insertionLevelAmbiguous",
                identifier="ambiguous",
                track_id="t",
                insertion_id="i",
            )
        ]
    }
    validated = worker._validated_brain3d_review_dispositions(
        context, tracks, candidates
    )
    assert validated == context["reviewDispositions"]

    context["reviewDispositions"].append(
        _manual_disposition(
            "plannedNotObserved",
            identifier="missing",
            insertion_id="i",
            shank_id="s0",
        )
    )
    with pytest.raises(worker.WorkerBlocked, match="ambiguous"):
        worker._validated_brain3d_review_dispositions(context, tracks, candidates)


def test_roi_traversal_uses_exact_voxel_and_half_open_box_intervals_without_double_counting(
    tmp_path: Path,
) -> None:
    annotation = np.full((4, 4, 4), 3, dtype=np.uint32)
    annotation[:2, :, :] = 2
    atlas = worker.AtlasData(
        name="allen_mouse_25um",
        version="1.2",
        reference=np.zeros_like(annotation, dtype=np.uint16),
        annotation=annotation,
        resolution=(10.0, 10.0, 10.0),
        orientation="asr",
        structures={
            1: {"structure_id_path": [1]},
            2: {"structure_id_path": [1, 2]},
            3: {"structure_id_path": [3]},
        },
        root_dir=tmp_path,
    )
    handoff = {
        "roi_sets": [
            {
                "roi_set_id": "roi-1",
                "name": "Overlapping members",
                "scope": "global",
                "insertion_snapshot_ids": [],
                "allen_structures": [
                    {"structure_id": 1, "include_descendants": True},
                    {"structure_id": 2, "include_descendants": False},
                ],
                "asr_boxes": [
                    {
                        "box_id": "box-1",
                        "minimum": {"ap_um": 5.0, "dv_um": 0.0, "ml_um": 0.0},
                        "maximum": {"ap_um": 25.0, "dv_um": 10.0, "ml_um": 10.0},
                    }
                ],
            }
        ]
    }
    tracks = [
        {
            "trackId": "observed-1",
            "endpointA": [10.0, 5.0, 5.0],
            "endpointB": [30.0, 5.0, 5.0],
        }
    ]
    candidates = [
        {
            "insertionSnapshotId": "insertion-1",
            "shankId": "shank-1",
            "entry": np.asarray([0.0, 5.0, 5.0]),
            "tip": np.asarray([40.0, 5.0, 5.0]),
        }
    ]

    summaries = worker.build_roi_summaries(
        handoff,
        tracks,
        candidates,
        [],
        atlas,
    )

    assert len(summaries) == 1
    summary = summaries[0]
    assert summary["planned"]["totalTraversalLengthMicrometres"] == pytest.approx(25.0)
    assert summary["observed"]["totalTraversalLengthMicrometres"] == pytest.approx(15.0)
    assert summary["intersection"]["traversedMemberKeys"] == [
        "allen:1:descendants",
        "allen:2:exact",
        "box:box-1",
    ]
    assert summary["union"] == summary["intersection"]
    assert summary["usableForNavigation"] is False


def test_locked_brain3d_atlas_identities_are_verified_without_override(
    tmp_path: Path,
) -> None:
    annotation = np.arange(64, dtype=np.uint32).reshape(4, 4, 4)
    metadata_path = tmp_path / "metadata.json"
    metadata_path.write_text('{"version":"1.2"}\n', encoding="utf-8")
    ontology_path = tmp_path / "exported-ontology.json"
    ontology_path.write_text('{"structures":[]}\n', encoding="utf-8")
    atlas = worker.AtlasData(
        name="allen_mouse_25um",
        version="1.2",
        reference=np.zeros_like(annotation, dtype=np.uint16),
        annotation=annotation,
        resolution=(25.0, 25.0, 25.0),
        orientation="asr",
        structures={
            1: {
                "id": 1,
                "acronym": "ROOT",
                "name": "Root",
                "structure_id_path": [1],
                "rgb_triplet": [1, 2, 3],
            }
        },
        root_dir=tmp_path,
    )
    locked_atlas = {
        "atlas_metadata_sha256": worker.hash_file(metadata_path),
        "annotation_sha256": worker._annotation_array_identity_sha256(atlas),
        "ontology_sha256": worker._brain3d_ontology_identity_sha256(atlas),
    }
    project = {"brain3dContext": {"handoff": {"atlas": locked_atlas}}}

    hashes = worker.atlas_provenance_hashes(project, atlas, ontology_path)
    assert hashes["atlasMetadata"] == locked_atlas["atlas_metadata_sha256"]
    assert hashes["annotationArrayIdentity"] == locked_atlas["annotation_sha256"]
    assert hashes["ontologyIdentity"] == locked_atlas["ontology_sha256"]

    locked_atlas["ontology_sha256"] = "f" * 64
    with pytest.raises(worker.WorkerBlocked, match="cannot be overridden"):
        worker.atlas_provenance_hashes(project, atlas, ontology_path)


def test_export_is_self_contained_and_writes_trajectory_samples(tmp_path: Path) -> None:
    reference = np.zeros((5, 32, 40), dtype=np.uint16)
    annotation = np.zeros_like(reference, dtype=np.uint32)
    reference[:, 4:29, 5:36] = 100
    annotation[:, 4:29, 5:36] = 42
    fixture = tmp_path / "atlas.npz"
    np.savez(
        fixture,
        reference=reference,
        annotation=annotation,
        resolution=np.asarray([25, 25, 25]),
    )
    source = tmp_path / "source.png"
    probe = tmp_path / "probe.png"
    review = tmp_path / "overlay.png"
    tissue_mask = tmp_path / "tissue-mask.png"
    Image.new("RGB", (40, 32), "white").save(source)
    Image.new("L", (40, 32), 180).save(probe)
    Image.new("RGB", (40, 32), "navy").save(review)
    Image.new("L", (40, 32), 255).save(tissue_mask)
    annotation_path = tmp_path / "annotation.tif"
    boundary_path = tmp_path / "boundary.png"
    transform_path = tmp_path / "affine.tfm"
    tifffile.imwrite(annotation_path, annotation[2])
    Image.new("RGB", (40, 32), "black").save(boundary_path)
    sitk.WriteTransform(sitk.AffineTransform(2), str(transform_path))
    slice_record = minimal_slice("accepted", source)
    slice_record["status"] = "accepted"
    slice_record["artifacts"] = {
        "structuralImagePath": str(source),
        "probeChannelImagePath": str(probe),
        "tissueMaskPath": str(tissue_mask),
        "overlayImagePath": str(review),
        "annotationImagePath": str(annotation_path),
        "boundaryImagePath": str(boundary_path),
        "transformPath": str(transform_path),
    }
    slice_record["transformChain"]["transforms"].append(
        {
            "id": "affine",
            "kind": "affine",
            "stage": "affine",
            "direction": "atlasToSlice",
            "engine": "synthetic",
            "affine": {"m00": 1, "m01": 0, "m10": 0, "m11": 1, "tx": 0, "ty": 0},
            "transformParametersPath": str(transform_path),
            "landmarks": [],
            "metric": 0.0,
            "createdAt": worker.utc_now(),
            "provenance": "synthetic",
            "coordinateUnit": "micron",
        }
    )
    slice_record["probeTrack"] = {
        "status": "atlasMapped",
        "confidence": 0.9,
        "reviewAccepted": True,
        "atlasPoints": [
            {
                "slicePoint": {"x": 1.0, "y": 1.0},
                "apMicrons": 50.0 + index * 25.0,
                "dorsalVentralMicrons": 250.0 + index * 10.0,
                "rightLeftMicrons": 300.0 + index * 5.0,
                "uncertaintyMicrons": 5.0,
            }
            for index in range(5)
        ],
    }
    second_slice = json.loads(json.dumps(slice_record))
    second_slice["id"] = "accepted-2"
    second_slice["title"] = "accepted-2"
    for point in second_slice["probeTrack"]["atlasPoints"]:
        point["apMicrons"] += 25.0
    project = minimal_project([slice_record, second_slice], fixture)
    project["colonySubjectReceipt"] = {
        "schemaVersion": 1,
        "service": "mouse_line",
        "publicId": "ML-2026-0001",
        "queryIdentifier": "ML-2026-0001",
        "matchedBy": "publicId",
        "subjectRecordSha256": "a" * 64,
        "verifiedAt": "2026-08-01T12:00:00Z",
        "sshHost": "hhw9l84",
        "sshRemotePort": 3004,
        "usableForNavigation": False,
    }
    project_path = tmp_path / "project.json"
    project_path.write_text(json.dumps(project), encoding="utf-8")
    export_root = tmp_path / "export"
    export_root.mkdir()
    (export_root / "stale-from-an-older-export.txt").write_text(
        "stale", encoding="utf-8"
    )
    (export_root / "atlas-export.json").write_text("{}", encoding="utf-8")
    result = worker.command_export_atlas(
        argparse.Namespace(project=project_path, out=export_root)
    )

    exported = result["export"]
    relative_paths = [
        exported["acceptedProjectPath"],
        exported["atlasOntologyPath"],
        exported["sliceExports"][0]["sourceImagePath"],
        exported["sliceExports"][0]["atlasCoordinateImagePath"],
        exported["sliceExports"][0]["regionOutlinesPath"],
        exported["sliceExports"][0]["transformChainPath"],
        exported["probeTrackPath"],
        exported["siteAssignmentsPath"],
        *exported["sliceExports"][0]["reviewArtifacts"].values(),
        *exported["provenance"]["parameterFiles"],
    ]
    relative_paths.extend(
        value
        for value in exported["sliceExports"][0]["sourceArtifacts"].values()
        if isinstance(value, str)
    )
    assert all(
        not Path(path).is_absolute() and (export_root / path).is_file()
        for path in relative_paths
    )
    assert exported["outputFolderPath"] == "."
    assert exported["siteAssignmentsPath"] == "trajectory-samples.csv"
    assert exported["provenance"]["atlasChecksum"]
    assert exported["colonySubjectReceipt"] == project["colonySubjectReceipt"]
    assert "fixtureArchive" in exported["provenance"]["atlasFileHashes"]
    assert "accepted:probe-channel" in exported["provenance"]["inputFileHashes"]

    portable_project = json.loads(
        (export_root / exported["acceptedProjectPath"]).read_text(encoding="utf-8")
    )
    assert portable_project["datasetRootPath"] == "."
    assert not Path(portable_project["slices"][0]["sourceImagePath"]).is_absolute()
    assert all(
        value is None or not Path(value).is_absolute()
        for key, value in portable_project["slices"][0]["artifacts"].items()
        if key.endswith("Path")
    )
    portable_affine = portable_project["slices"][0]["transformChain"]["transforms"][-1]
    assert not Path(portable_affine["transformParametersPath"]).is_absolute()

    ontology = json.loads(
        (export_root / exported["atlasOntologyPath"]).read_text(encoding="utf-8")
    )
    assert ontology["structures"] == [
        {
            "acronym": "42",
            "id": 42,
            "name": "Fixture region 42",
            "parentStructureID": None,
            "rgbTriplet": [170, 170, 170],
            "structureIDPath": [],
        }
    ]
    for relative, digest in exported["provenance"]["exportFileHashes"].items():
        assert not Path(relative).is_absolute()
        assert worker.hash_file(export_root / relative) == digest
    assert (
        "stale-from-an-older-export.txt"
        not in exported["provenance"]["exportFileHashes"]
    )
    assert "atlas-export.json" not in exported["provenance"]["exportFileHashes"]

    track = json.loads(
        (export_root / exported["probeTrackPath"]).read_text(encoding="utf-8")
    )
    assert track["distinctSliceCount"] == 2
