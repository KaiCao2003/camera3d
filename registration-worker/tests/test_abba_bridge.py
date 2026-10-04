from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest
import tifffile
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import abba_bridge as bridge


@pytest.fixture
def project(tmp_path: Path) -> Path:
    rgba = np.zeros((3, 4, 4), dtype=np.uint8)
    rgba[..., 0] = np.arange(12, dtype=np.uint8).reshape(3, 4) * 20
    rgba[..., 3] = 255
    rgba[0, 0] = [255, 0, 0, 0]
    Image.fromarray(rgba).save(tmp_path / "structural.png")
    probe = rgba.copy()
    probe[..., 1] = probe[..., 0]
    probe[..., 0] = 0
    Image.fromarray(probe).save(tmp_path / "probe.png")
    path = tmp_path / "project.json"
    path.write_text(json.dumps({"id": "mouse-test", "atlas": {"id": "allen_mouse_25um", "version": "1.2"},
        "pixelSizeMicrons": 10, "slices": [{"id": "section-01", "sourceImagePath": "structural.png",
        "artifacts": {"rawProbeChannelImagePath": "probe.png"},
        "pose": {"rotationDegrees": 180, "atlasAnchoring": [400, 250, 300, -300, 0, 0, 0, 0, -200]}}]}))
    return path


def test_export_preserves_canonical_pixels_anchor_and_channel_identity(project: Path, tmp_path: Path):
    before = project.read_bytes()
    output = tmp_path / "handoff"
    result = bridge.export_bundle(project, output)
    manifest = bridge.load_bundle(output)
    quicknii = bridge.read_json(Path(result["quickniiPath"]))
    expected = np.rot90(np.arange(12, dtype=np.uint8).reshape(3, 4) * 20, 2)
    assert np.array_equal(tifffile.imread(output / "section_s0000.tif"), expected)
    assert np.array_equal(tifffile.imread(output / "section_s0000_probe.tif"), expected)
    assert quicknii["slices"][0]["anchoring"] == [400, 250, 300, -300, 0, 0, 0, 0, -200]
    assert quicknii["slices"][0]["width"] == 4
    assert manifest["slices"][0]["sliceID"] == "section-01"
    assert manifest["slices"][0]["pixelSizeMicrons"] == 10
    assert "not_registered" in manifest["registrationStatus"]
    assert project.read_bytes() == before


def test_export_detects_stale_canonical_orientation(project: Path, tmp_path: Path):
    data = bridge.read_json(project)
    data["slices"][0]["canonicalRasterOrientation"] = {"rotationDegrees": 0}
    bridge.write_json(project, data)
    with pytest.raises(bridge.BridgeBlocked, match="stale"):
        bridge.export_bundle(project, tmp_path / "stale")
    assert not (tmp_path / "stale").exists()


def test_existing_canonical_is_not_rotated_twice(project: Path, tmp_path: Path):
    data = bridge.read_json(project)
    data["slices"][0]["canonicalRasterOrientation"] = {"rotationDegrees": 180}
    data["slices"][0]["artifacts"] = {"structuralImagePath": "structural.png"}
    bridge.write_json(project, data)
    bridge.export_bundle(project, tmp_path / "canonical")
    assert tifffile.imread(tmp_path / "canonical/section_s0000.tif")[2, 3] == 220


@pytest.mark.parametrize("anchor", [None, [1, 2, 3], [0] * 9, [float("nan")] * 9])
def test_invalid_plane_never_creates_a_bundle(project: Path, tmp_path: Path, anchor):
    data = bridge.read_json(project)
    data["slices"][0]["pose"]["atlasAnchoring"] = anchor
    project.write_text(json.dumps(data))
    with pytest.raises(bridge.BridgeBlocked):
        bridge.export_bundle(project, tmp_path / "invalid")
    assert not (tmp_path / "invalid").exists()


def test_bundle_hash_detects_changed_image(project: Path, tmp_path: Path):
    output = tmp_path / "handoff"
    bridge.export_bundle(project, output)
    with (output / "section_s0000.tif").open("ab") as stream:
        stream.write(b"changed")
    with pytest.raises(bridge.BridgeBlocked, match="checksum"):
        bridge.load_bundle(output)


def test_official_xyz_mapping_is_explicit_not_a_quicknii_origin_adjustment():
    xyz = np.asarray([[[1.2]], [[2.3]], [[3.4]]], dtype=np.float32)
    np.testing.assert_allclose(bridge.abba_xyz_to_asr_um(xyz)[:, 0, 0], [3400, 2300, 1200])


def test_cli_failure_writes_swift_envelope(project: Path, tmp_path: Path):
    result_path = tmp_path / "result.json"
    process = subprocess.run([sys.executable, str(Path(bridge.__file__)), "export", "--project", str(project),
        "--output", str(tmp_path / "new"), "--slice-id", "does-not-exist", "--result-json", str(result_path)], capture_output=True, text=True)
    assert process.returncode == 2
    result = bridge.read_json(result_path)
    assert result["stage"] == "blocked"
    assert result["command"] == "abba-export"
    assert result["projectID"] == "mouse-test"
    assert result["outputPath"] is None
    assert not (tmp_path / "new").exists()


def test_reexport_never_overwrites_an_existing_bundle(project: Path, tmp_path: Path):
    output = tmp_path / "handoff"
    bridge.export_bundle(project, output)
    digest = bridge.sha256(output / "manifest.json")
    with pytest.raises(bridge.BridgeBlocked, match="new export directory"):
        bridge.export_bundle(project, output)
    assert bridge.sha256(output / "manifest.json") == digest


def test_import_formula_matches_official_oblique_slice_corner():
    # Real ABBA 0.11 import at source pixel (0, 0). This regression covers
    # the half-pixel center shift and depth coupled through the plane normal.
    entry = {"width": 492, "height": 293, "anchoring": [
        440.8415259806287, 160.38360686387463, 343.88561521331843,
        -432.8870814741345, -0.8135047336207037, -28.105285275570395,
        12.971822156437156, -15.968232469387374, -328.1648189833214]}
    slicing_to_atlas = np.array([
        [0.999999185, 0.0000619843719, 0, 5.7],
        [0, 0.998820688, 0, 4], [-0.00127667645, 0.0485513155, 1, -0.975],
        [0, 0, 0, 1]])
    actual = bridge.expected_quicknii_import(entry, slicing_to_atlas) @ [0, 0, 0, 1]
    np.testing.assert_allclose(actual[:3], [0.38973756556914474, -0.5950277162018985,
                                         9.190498765188337], atol=1e-8, rtol=0)


def test_wait_without_registration_does_not_count_as_success():
    class ImportedSlice:
        def getNumberOfRegistrations(self):
            return 1
    with pytest.raises(RuntimeError, match="did not complete"):
        bridge.verify_stage([ImportedSlice()], [2], [], "affine")
    with pytest.raises(RuntimeError, match="registration failed"):
        bridge.verify_stage([ImportedSlice()], [1], ["registration failed"], "import")


def test_official_elastix_wrapper_requires_its_real_bin_layout(tmp_path: Path):
    with pytest.raises(bridge.BridgeBlocked, match="actual bin/elastix"):
        bridge.elastix_binary_version(tmp_path / "elastix-launch", "elastix")


@pytest.fixture
def completed_result(project: Path, tmp_path: Path):
    bundle = tmp_path / "handoff"
    bridge.export_bundle(project, bundle)
    manifest = bridge.load_bundle(bundle)
    original = manifest["slices"][0]
    coordinates = tmp_path / "coordinates.tif"
    tifffile.imwrite(coordinates, np.zeros((3, 3, 4), dtype=np.float32), photometric="minisblack")
    path = tmp_path / "result.json"
    bridge.write_json(path, {"schemaVersion": 1, "status": "official_abba_completed", "stage": "spline",
        "projectID": manifest["projectID"], "projectSHA256": manifest["projectSHA256"],
        "bundleManifestSHA256": bridge.sha256(bundle / "manifest.json"),
        "atlas": manifest["atlas"], "abbaPythonVersion": bridge.ABBA_VERSION,
        "coordinateFrame": "BRAINGLOBE_PHYSICAL_ASR_UM", "coordinateOrder": ["AP", "DV", "ML"],
        "coordinateUnit": "micrometre", "coordinateImageAxes": "CYX", "pixelOrigin": "zero_based_pixel_centres",
        "slices": [{"sliceID": original["sliceID"], "width": 4, "height": 3,
                    "structuralSHA256": original["structuralSHA256"], "completedRegistrationCount": 3,
                    "atlasCoordinatesFile": coordinates.name, "atlasCoordinatesSHA256": bridge.sha256(coordinates)}]})
    return bundle, path


@pytest.mark.parametrize("field,value", [("completedRegistrationCount", 2), ("structuralSHA256", "wrong"),
                                         ("width", 5), ("atlasCoordinatesSHA256", "wrong")])
def test_result_rejects_incomplete_or_mismatched_slice(completed_result, field, value):
    bundle, path = completed_result
    result = bridge.read_json(path)
    result["slices"][0][field] = value
    bridge.write_json(path, result)
    with pytest.raises(bridge.BridgeBlocked):
        bridge.validate_result(bundle, path)


def test_result_rejects_corrupted_coordinates_and_wrong_units(completed_result):
    bundle, path = completed_result
    assert bridge.validate_result(bundle, path)["status"] == "validated"
    result = bridge.read_json(path)
    coordinates = path.parent / result["slices"][0]["atlasCoordinatesFile"]
    tifffile.imwrite(coordinates, np.ones((3, 3, 4), dtype=np.float32), photometric="minisblack")
    with pytest.raises(bridge.BridgeBlocked, match="Invalid result coordinate"):
        bridge.validate_result(bundle, path)
    result["coordinateUnit"] = "millimetre"
    bridge.write_json(path, result)
    with pytest.raises(bridge.BridgeBlocked, match="image convention"):
        bridge.validate_result(bundle, path)


def test_review_cli_does_not_create_images_for_a_tampered_result(completed_result, tmp_path: Path):
    bundle, path = completed_result
    result = bridge.read_json(path)
    result["slices"][0]["atlasCoordinatesSHA256"] = "changed"
    bridge.write_json(path, result)
    envelope, output = tmp_path / "envelope.json", tmp_path / "review"
    process = subprocess.run([sys.executable, str(Path(bridge.__file__)), "prepare-review",
        "--bundle", str(bundle), "--result", str(path), "--out", str(output),
        "--result-json", str(envelope)], capture_output=True, text=True)
    assert process.returncode == 2
    assert not output.exists()
    response = bridge.read_json(envelope)
    assert response["command"] == "abba-review"
    assert response["stage"] == "blocked"
    assert response["outputPath"] is None
