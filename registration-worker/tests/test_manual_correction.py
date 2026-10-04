from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pytest
import SimpleITK as sitk
from PIL import Image

from test_worker import feature_image, minimal_project, minimal_slice, save_rgba
import brainbuilder_worker as worker


def fixture_project(tmp_path: Path, rotation: int = 0) -> tuple[dict, worker.AtlasData]:
    gray, mask = feature_image()
    fixture = tmp_path / "atlas.npz"
    np.savez(
        fixture,
        reference=np.repeat((gray * 1000).astype(np.uint16)[None], 25, axis=0),
        annotation=np.repeat(mask.astype(np.uint32)[None], 25, axis=0),
        resolution=np.asarray([25.0, 25.0, 25.0]),
    )
    source = tmp_path / "raw.png"
    save_rgba(source, np.rot90(gray, rotation // 90), np.rot90(mask, rotation // 90))
    record = minimal_slice("manual-section", source)
    record["pose"]["atlasAPMicrons"] = 300.0
    record["pose"]["rotationDegrees"] = rotation
    # QuickNII -> ASR gives the same 160 x 120 image and preserves image pixels.
    record["pose"]["atlasAnchoring"] = [159, 12, 119, -160, 0, 0, 0, 0, -120]
    project = minimal_project([record], fixture)
    return project, worker.load_atlas(project, annotations=True)


def pairs_for_transform(matrix: np.ndarray, offset: np.ndarray) -> list[worker.CorrectionLandmark]:
    points = np.asarray([[25, 25], [110, 25], [25, 80], [100, 80]], dtype=float)
    mapped = points @ matrix.T + offset
    return [
        worker.CorrectionLandmark(
            id=str(index), atlasPoint={"x": float(a[0]), "y": float(a[1])},
            slicePoint={"x": float(b[0]), "y": float(b[1])}, label=f"Pair {index}",
        )
        for index, (a, b) in enumerate(zip(points, mapped, strict=True))
    ]


def test_landmark_affine_recovers_physical_mapping_and_inverse(tmp_path: Path) -> None:
    project, atlas = fixture_project(tmp_path)
    plane = worker.atlas_plane(atlas, project["slices"][0]["pose"], (120, 160), 25)
    pixel_matrix = np.asarray([[0.92, 0.06], [-0.04, 1.02]])
    pixel_offset = np.asarray([4.0, 3.0])
    pairs = pairs_for_transform(pixel_matrix, pixel_offset)
    fitted, rms = worker.affine_from_landmarks(pairs, plane, (120, 160), 10)
    assert rms < 1e-10
    assert np.asarray(fitted.GetMatrix()).reshape(2, 2) == pytest.approx(pixel_matrix * 10 / 25)
    assert fitted.GetTranslation() == pytest.approx(pixel_offset * 10)
    held_out = np.asarray([64.0, 51.0])
    mapped = np.asarray(fitted.TransformPoint(tuple(held_out * 25)))
    assert mapped == pytest.approx((pixel_matrix @ held_out + pixel_offset) * 10)
    assert fitted.GetInverse().TransformPoint(tuple(mapped)) == pytest.approx(held_out * 25)


@pytest.mark.parametrize("kind", ["collinear", "too_few", "mirrored", "outside"])
def test_landmark_affine_rejects_invalid_geometry(tmp_path: Path, kind: str) -> None:
    project, atlas = fixture_project(tmp_path)
    plane = worker.atlas_plane(atlas, project["slices"][0]["pose"], (120, 160), 25)
    pairs = pairs_for_transform(np.eye(2), np.zeros(2))
    if kind == "collinear":
        for p in pairs:
            p.atlasPoint.y = 30
    elif kind == "too_few":
        pairs = pairs[:2]
    elif kind == "mirrored":
        for p in pairs:
            p.slicePoint.x = 150 - p.atlasPoint.x
    else:
        pairs[0].slicePoint.x = 160
    with pytest.raises(worker.WorkerBlocked):
        worker.affine_from_landmarks(pairs, plane, (120, 160), 25)


def test_manual_plane_rotates_anchoring_and_preserves_extent_and_raster(tmp_path: Path) -> None:
    project, atlas = fixture_project(tmp_path, rotation=180)
    old = project["slices"][0]["pose"]
    request = worker.SliceCorrection(atlasAPMicrons=350, pitchDegrees=6, yawDegrees=-8)
    new = worker.corrected_pose(old, request, atlas)
    a = np.asarray(new["atlasAnchoring"])
    old_a = np.asarray(old["atlasAnchoring"])
    for vector in (slice(3, 6), slice(6, 9)):
        assert np.linalg.norm(a[vector]) == pytest.approx(np.linalg.norm(old_a[vector]))
    assert np.dot(a[3:6], a[6:9]) == pytest.approx(np.dot(old_a[3:6], old_a[6:9]), abs=1e-9)
    normal = np.cross(a[3:6], a[6:9])
    center = np.asarray([80.0, 24 - 350 / 25, 60.0])
    assert np.dot(normal, center - a[:3]) == pytest.approx(0, abs=1e-7)
    assert new["atlasSlicingAngles"]["pitchDegrees"] == pytest.approx(6)
    assert new["atlasSlicingAngles"]["rollDegrees"] == pytest.approx(-8)
    assert new["rotationDegrees"] == 180
    assert new["manuallyLocked"] is True
    assert old["atlasAPMicrons"] == 300
    old_plane = worker.atlas_plane(atlas, old, (120, 160), 25)
    new_plane = worker.atlas_plane(atlas, new, (120, 160), 25)
    assert np.max(np.abs(old_plane.atlas_u - new_plane.atlas_u)) > 1


def test_manual_command_preserves_old_files_and_resets_review(tmp_path: Path, monkeypatch) -> None:
    project, _ = fixture_project(tmp_path, rotation=180)
    record = project["slices"][0]
    record["status"] = "accepted"
    old_transform = tmp_path / "old-affine.tfm"
    sitk.WriteTransform(sitk.AffineTransform(2), str(old_transform))
    old_bytes = old_transform.read_bytes()
    record["artifacts"] = {"transformPath": str(old_transform)}
    record["probeTrack"] = {"accepted": True, "points": []}
    record["probeTrackCandidates"] = [{"accepted": True, "points": []}]
    project["blindReviewLocked"] = False
    project["blindTrackReview"] = {"stale": True}
    project["brain3dContext"] = {"blindReviewLocked": False, "reviewDispositions": [{"stale": True}]}
    source_project = tmp_path / "source-project.json"
    worker.write_json(source_project, project)
    source_bytes = source_project.read_bytes()
    pairs = pairs_for_transform(np.asarray([[0.94, 0.02], [-0.01, 1.02]]), np.asarray([3, 2]))
    request = worker.SliceCorrection(
        atlasAPMicrons=300, pitchDegrees=0, yawDegrees=0, landmarks=pairs,
    )
    correction_file = tmp_path / "correction.json"
    correction_file.write_text(request.model_dump_json())
    monkeypatch.setattr(
        worker, "register_affine",
        lambda *a, **k: pytest.fail("MI must not overwrite manual landmarks"),
    )
    args = argparse.Namespace(
        project=source_project, slice_id=record["id"], correction_json=correction_file,
        out=tmp_path / "new-run", command="correct-slice",
    )
    result = worker.command_correct_slice(args)
    updated = result["slice"]
    assert result["stage"] == "ok"
    assert updated["status"] == "needsReview"
    assert updated["pose"]["manuallyLocked"] is True
    assert updated["qc"]["landmarkRMSErrorMicrons"] < 1e-9
    assert updated["qc"]["mutualInformationMetric"] is None
    assert updated["transformChain"]["transforms"][-1]["stage"] == "manual"
    assert updated["transformChain"]["transforms"][-1]["landmarks"] == [p.model_dump() for p in pairs]
    assert worker.valid_affine_transform_record(updated["transformChain"]["transforms"][-1])
    assert updated["probeTrackCandidates"] == []
    assert result["project"]["blindReviewLocked"] is False
    assert "blindTrackReview" not in result["project"]
    assert result["project"]["brain3dContext"]["reviewDispositions"] == []
    assert source_project.read_bytes() == source_bytes
    assert old_transform.read_bytes() == old_bytes
    assert (args.out / "prior-slice.json").exists()
    assert (args.out / "project.json").exists()
    canonical = np.asarray(Image.open(updated["artifacts"]["structuralImagePath"]))
    raw = np.asarray(Image.open(record["sourceImagePath"]))
    np.testing.assert_array_equal(canonical, np.rot90(raw, 2))
    with pytest.raises(worker.WorkerBlocked, match="new output run"):
        worker.command_correct_slice(args)


def test_manual_command_rejects_landmarks_on_changed_plane(tmp_path: Path) -> None:
    project, _ = fixture_project(tmp_path)
    source_project = tmp_path / "source-project.json"
    worker.write_json(source_project, project)
    request = worker.SliceCorrection(
        atlasAPMicrons=350, pitchDegrees=0, yawDegrees=0,
        landmarks=pairs_for_transform(np.eye(2), np.zeros(2)),
    )
    correction_file = tmp_path / "correction.json"
    correction_file.write_text(request.model_dump_json())
    args = argparse.Namespace(
        project=source_project, slice_id=project["slices"][0]["id"], correction_json=correction_file,
        out=tmp_path / "new-run", command="correct-slice",
    )
    with pytest.raises(worker.WorkerBlocked, match="changed atlas plane first"):
        worker.command_correct_slice(args)
    assert not args.out.exists()


@pytest.mark.parametrize("lock_location", ["project", "brain3dContext"])
def test_manual_command_refuses_locked_blind_review(tmp_path: Path, lock_location: str) -> None:
    project, _ = fixture_project(tmp_path)
    if lock_location == "project":
        project["blindReviewLocked"] = True
    else:
        project["brain3dContext"] = {"blindReviewLocked": True}
    source_project = tmp_path / "source-project.json"
    worker.write_json(source_project, project)
    args = argparse.Namespace(
        project=source_project, slice_id=project["slices"][0]["id"],
        correction_json=tmp_path / "unused.json", out=tmp_path / "new-run",
    )
    with pytest.raises(worker.WorkerBlocked, match="Unlock blind review"):
        worker.command_correct_slice(args)
    assert not args.out.exists()


def test_track_mapping_does_not_claim_line_residual_as_atlas_uncertainty(tmp_path: Path) -> None:
    project, atlas = fixture_project(tmp_path)
    plane = worker.atlas_plane(atlas, project["slices"][0]["pose"], (120, 160), 25)
    detection = {"points": [{"x": 40, "y": 50, "inlier": True}], "rmseMicrons": 7}
    worker.map_track_to_atlas(detection, sitk.AffineTransform(2), 25, plane, atlas)
    assert detection["atlasPoints"][0]["uncertaintyMicrons"] is None
    assert detection["rmseMicrons"] == 7
