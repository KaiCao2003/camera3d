from __future__ import annotations

from pathlib import Path
import sys

import numpy as np
from PIL import Image
import pytest
import tifffile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import abba_bridge as bridge
import brainbuilder_worker as worker


@pytest.fixture
def raw_section(tmp_path: Path):
    yy, xx = np.mgrid[:120, :160]
    domain = np.zeros((120, 160), dtype=bool)
    domain[8:108, 12:148] = True
    # A bright neighbouring section touches the crop bottom but is outside
    # the selected section domain, as in the real XY04 montage crop.
    values = np.full(domain.shape, 12, dtype=np.uint8)
    tissue = ((xx - 75) / 53) ** 2 + ((yy - 56) / 36) ** 2 <= 1
    values[tissue] = (70 + xx[tissue] * 0.6).astype(np.uint8)
    values[45:52, 42:100] = 48
    values[111:, 20:130] = 245
    rgba = np.zeros((*domain.shape, 4), dtype=np.uint8)
    rgba[..., 0] = values
    # An all-zero preview alpha must not erase raw RGB inside an explicit domain.
    image_path, mask_path = tmp_path / "raw.png", tmp_path / "selection.png"
    Image.fromarray(rgba).save(image_path)
    Image.fromarray(domain.astype(np.uint8) * 255).save(mask_path)
    return image_path, mask_path, rgba, domain


def test_explicit_selection_preserves_transparent_raw_signal_and_excludes_neighbour(raw_section):
    image_path, mask_path, rgba, domain = raw_section
    prepared = worker.load_prepared_image(image_path, selection_mask_path=mask_path)
    np.testing.assert_array_equal(prepared.selection_domain, domain)
    np.testing.assert_allclose(prepared.rgb[domain], rgba[..., :3][domain].astype(np.float32) / 255)
    assert not prepared.rgb[~domain].any()
    assert prepared.rgb[47, 50, 0] == pytest.approx(48 / 255)
    assert not prepared.rgb[114, 50].any()
    assert prepared.mask.any()
    assert not prepared.mask[~domain].any()
    assert not np.array_equal(prepared.mask, domain)
    assert not prepared.mask[10:20, 14:25].any()


def test_orientation_moves_structure_and_domain_together_without_double_rotation(raw_section, tmp_path: Path):
    image_path, mask_path, rgba, domain = raw_section
    pose = {"rotationDegrees": 180}
    record = {"id": "section", "sourceImagePath": str(image_path), "pose": pose,
              "artifacts": {"selectionMaskPath": str(mask_path)}}
    prepared = worker.load_prepared_image(image_path, pose, selection_mask_path=mask_path)
    expected_rgba, expected_domain = np.rot90(rgba, 2), np.rot90(domain, 2)
    np.testing.assert_array_equal(prepared.rgba, expected_rgba)
    np.testing.assert_array_equal(prepared.selection_domain, expected_domain)
    worker.materialize_oriented_source_artifacts(record, prepared, tmp_path / "canonical")
    artifacts = record["artifacts"]
    assert Path(artifacts["rawSelectionMaskPath"]) == mask_path.resolve()
    assert Path(artifacts["rawStructuralImagePath"]) == image_path.resolve()
    np.testing.assert_array_equal(np.asarray(Image.open(artifacts["structuralImagePath"])), expected_rgba)
    np.testing.assert_array_equal(np.asarray(Image.open(artifacts["selectionMaskPath"])) > 0, expected_domain)
    replay = worker.load_prepared_image(worker.source_raster_path(record, "structural"), pose,
                                       selection_mask_path=worker.source_raster_path(record, "selectionMask"))
    worker.materialize_oriented_source_artifacts(record, replay, tmp_path / "canonical")
    np.testing.assert_array_equal(replay.rgba, expected_rgba)
    np.testing.assert_array_equal(replay.selection_domain, expected_domain)
    np.testing.assert_array_equal(np.asarray(Image.open(artifacts["selectionMaskPath"])) > 0, expected_domain)


def test_abba_export_preserves_raw_intensities_and_selection_sidecar_after_canonicalization(raw_section, tmp_path: Path):
    image_path, mask_path, rgba, domain = raw_section
    pose = {"rotationDegrees": 180, "atlasAnchoring": [400, 250, 300, -300, 0, 0, 0, 0, -200]}
    record = {"id": "section", "sourceImagePath": str(image_path), "pose": pose,
              "artifacts": {"selectionMaskPath": str(mask_path)}}
    prepared = worker.load_prepared_image(image_path, pose, selection_mask_path=mask_path)
    worker.materialize_oriented_source_artifacts(record, prepared, tmp_path / "canonical")
    project_path = tmp_path / "project.json"
    bridge.write_json(project_path, {"id": "selection-test", "atlas": {"id": "allen_mouse_25um", "version": "1.2"},
                                     "pixelSizeMicrons": 10, "slices": [record]})
    bundle = tmp_path / "abba"
    bridge.export_bundle(project_path, bundle)
    manifest = bridge.load_bundle(bundle)
    entry = manifest["slices"][0]
    expected = np.rot90(np.where(domain, rgba[..., :3].max(-1), 0), 2)
    np.testing.assert_array_equal(tifffile.imread(bundle / entry["structuralFile"]), expected)
    exported_mask = np.asarray(Image.open(bundle / entry["selectionMaskFile"])) > 0
    np.testing.assert_array_equal(exported_mask, np.rot90(domain, 2))
    assert entry["selectionMaskSHA256"] == bridge.sha256(bundle / entry["selectionMaskFile"])
    assert entry["sourceSelectionMaskSHA256"] == bridge.sha256(Path(entry["sourceSelectionMaskPath"]))
    Image.fromarray(np.zeros(domain.shape, dtype=np.uint8)).save(bundle / entry["selectionMaskFile"])
    with pytest.raises(bridge.BridgeBlocked, match="checksum"):
        bridge.load_bundle(bundle)


@pytest.mark.parametrize("mutation", ["change_pixels", "remove_paths"])
def test_worker_rejects_changed_raw_selection_after_canonical_preparation(raw_section, tmp_path: Path, mutation: str):
    image_path, mask_path, _, domain = raw_section
    record = {"id": "section", "sourceImagePath": str(image_path), "pose": {"rotationDegrees": 180},
              "artifacts": {"selectionMaskPath": str(mask_path)}}
    project = {"provenance": {"selectionMaskHashes": {"section": bridge.sha256(mask_path)}}}
    prepared = worker.load_prepared_image(image_path, record["pose"], selection_mask_path=mask_path)
    worker.materialize_oriented_source_artifacts(record, prepared, tmp_path / "canonical")
    worker.verify_selection_mask_identity(project, record)
    if mutation == "change_pixels":
        changed = domain.copy()
        changed[15, 20] = False
        Image.fromarray(changed.astype(np.uint8) * 255).save(mask_path)
    else:
        record["artifacts"].pop("selectionMaskPath")
        record["artifacts"].pop("rawSelectionMaskPath")
    with pytest.raises(worker.WorkerBlocked, match="Selection-domain mask changed"):
        worker.verify_selection_mask_identity(project, record)


@pytest.mark.parametrize("mutation", ["change_pixels", "remove_paths"])
def test_abba_rejects_changed_raw_selection_before_creating_bundle(raw_section, tmp_path: Path, mutation: str):
    image_path, mask_path, _, domain = raw_section
    pose = {"rotationDegrees": 180, "atlasAnchoring": [400, 250, 300, -300, 0, 0, 0, 0, -200]}
    record = {"id": "section", "sourceImagePath": str(image_path), "pose": pose,
              "artifacts": {"selectionMaskPath": str(mask_path)}}
    project = {"id": "selection-test", "atlas": {"id": "allen_mouse_25um", "version": "1.2"},
               "pixelSizeMicrons": 10, "slices": [record],
               "provenance": {"selectionMaskHashes": {"section": bridge.sha256(mask_path)}}}
    prepared = worker.load_prepared_image(image_path, pose, selection_mask_path=mask_path)
    worker.materialize_oriented_source_artifacts(record, prepared, tmp_path / "canonical")
    project_path = tmp_path / "project.json"
    if mutation == "change_pixels":
        changed = domain.copy()
        changed[15, 20] = False
        Image.fromarray(changed.astype(np.uint8) * 255).save(mask_path)
    else:
        record["artifacts"].pop("selectionMaskPath")
        record["artifacts"].pop("rawSelectionMaskPath")
    bridge.write_json(project_path, project)
    output = tmp_path / "rejected-abba"
    with pytest.raises(bridge.BridgeBlocked, match="Selection-domain mask"):
        bridge.export_bundle(project_path, output)
    assert not output.exists()


def test_pose_orientation_change_restores_raw_selection_grid(raw_section, tmp_path: Path):
    image_path, mask_path, _, domain = raw_section
    record = {"id": "section", "sourceImagePath": str(image_path), "pose": {"rotationDegrees": 180},
              "artifacts": {"selectionMaskPath": str(mask_path)}}
    prepared = worker.load_prepared_image(image_path, record["pose"], selection_mask_path=mask_path)
    worker.materialize_oriented_source_artifacts(record, prepared, tmp_path / "canonical")
    assert record["canonicalRasterOrientation"]["rotationDegrees"] == 180
    worker.install_pose(record, {"rotationDegrees": 0}, engine="test")
    assert "canonicalRasterOrientation" not in record
    assert Path(record["artifacts"]["selectionMaskPath"]) == mask_path.resolve()
    assert Path(record["artifacts"]["structuralImagePath"]) == image_path.resolve()
    reloaded = worker.load_prepared_image(Path(record["artifacts"]["structuralImagePath"]), record["pose"],
                                         selection_mask_path=Path(record["artifacts"]["selectionMaskPath"]))
    np.testing.assert_array_equal(reloaded.selection_domain, domain)
