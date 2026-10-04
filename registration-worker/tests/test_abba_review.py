from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest
import tifffile
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import abba_bridge as bridge
from abba_review import prepare_review


@pytest.fixture
def review_inputs(tmp_path: Path):
    atlas = tmp_path / "atlas"
    atlas.mkdir()
    reference = (np.arange(60).reshape(3, 4, 5) * 8).astype(np.uint16)
    annotation = np.zeros(reference.shape, dtype=np.uint32)
    annotation[1, 1:3, 1:4] = 7
    tifffile.imwrite(atlas / "reference.tiff", reference, photometric="minisblack")
    tifffile.imwrite(atlas / "annotation.tiff", annotation, photometric="minisblack")
    bridge.write_json(atlas / "metadata.json", {"orientation": "asr", "version": "1.2",
        "resolution": [25, 25, 25], "shape": list(reference.shape)})
    source = np.arange(12, dtype=np.uint8).reshape(3, 4) * 20
    Image.fromarray(source).save(tmp_path / "source.png")
    project = tmp_path / "project.json"
    bridge.write_json(project, {"id": "review-test", "atlas": {"id": "allen_mouse_25um", "version": "1.2"},
        "atlasAssets": {"atlasRootPath": str(atlas)}, "pixelSizeMicrons": 10,
        "slices": [{"id": "section", "title": "Test section", "sourceImagePath": "source.png",
                    "pose": {"atlasAnchoring": [400, 250, 300, -300, 0, 0, 0, 0, -200]}}]})
    bundle = tmp_path / "bundle"
    bridge.export_bundle(project, bundle)
    manifest = bridge.load_bundle(bundle)
    yy, xx = np.mgrid[:3, :4]
    field = np.stack([np.full(xx.shape, 25), (yy + 0.5) * 25, (xx + 0.25) * 25]).astype(np.float32)
    field_path = tmp_path / "field.tif"
    tifffile.imwrite(field_path, field, photometric="minisblack")
    state = tmp_path / "registration.abba"
    state.write_bytes(b"test state")
    result_path = tmp_path / "result.json"
    bridge.write_json(result_path, {"schemaVersion": 1, "status": "official_abba_completed", "stage": "spline",
        "projectID": manifest["projectID"], "projectSHA256": manifest["projectSHA256"],
        "bundleManifestSHA256": bridge.sha256(bundle / "manifest.json"), "atlas": manifest["atlas"],
        "abbaPythonVersion": bridge.ABBA_VERSION, "coordinateFrame": "BRAINGLOBE_PHYSICAL_ASR_UM",
        "coordinateOrder": ["AP", "DV", "ML"], "coordinateUnit": "micrometre",
        "coordinateImageAxes": "CYX", "pixelOrigin": "zero_based_pixel_centres",
        "stateFile": state.name, "stateSHA256": bridge.sha256(state),
        "slices": [{"sliceID": "section", "width": 4, "height": 3, "completedRegistrationCount": 3,
            "structuralSHA256": manifest["slices"][0]["structuralSHA256"], "atlasCoordinatesFile": field_path.name,
            "atlasCoordinatesSHA256": bridge.sha256(field_path)}]})
    return bundle, result_path, project, source


def test_review_preserves_source_and_samples_asr_physical_coordinates(review_inputs, tmp_path: Path):
    bundle, result_path, project, source = review_inputs
    original_project = project.read_bytes()
    output = prepare_review(bundle, result_path, tmp_path / "review")
    review = bridge.read_json(Path(output["reviewPath"]))
    entry = review["slices"][0]
    np.testing.assert_array_equal(np.asarray(Image.open(entry["histologyPath"])), source)
    yy, xx = np.mgrid[:3, :4]
    expected_reference = 8 * (20 + (yy + 0.5) * 5 + (xx + 0.25))
    expected_display = np.rint(expected_reference / (59 * 8) * 255).astype(np.uint8)
    np.testing.assert_array_equal(np.asarray(Image.open(entry["atlasPath"])), expected_display)
    for key in ("histologyPath", "atlasPath", "overlayPath"):
        assert Path(entry[key]).is_absolute()
        assert Image.open(entry[key]).size == (4, 3)
    assert review["displayWindow"]["atlas"] == [0, 472]
    assert entry["anatomicalReview"] == "required"
    assert project.read_bytes() == original_project


def test_direct_review_rejects_tampered_fields_before_creating_output(review_inputs, tmp_path: Path):
    bundle, result_path, _, _ = review_inputs
    result = bridge.read_json(result_path)
    result["slices"][0]["atlasCoordinatesSHA256"] = "changed"
    bridge.write_json(result_path, result)
    out = tmp_path / "review"
    with pytest.raises(bridge.BridgeBlocked, match="Invalid result coordinate"):
        prepare_review(bundle, result_path, out)
    assert not out.exists()


def test_review_never_overwrites_existing_images(review_inputs, tmp_path: Path):
    bundle, result_path, _, _ = review_inputs
    out = tmp_path / "review"
    prepare_review(bundle, result_path, out)
    before = bridge.sha256(out / "review.json")
    with pytest.raises(bridge.BridgeBlocked, match="new review directory"):
        prepare_review(bundle, result_path, out)
    assert bridge.sha256(out / "review.json") == before
