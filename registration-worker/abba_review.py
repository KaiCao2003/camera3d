"""Prepare source-grid images for read-only review of validated official ABBA results."""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage
import tifffile


def annotation_boundaries(labels: np.ndarray) -> np.ndarray:
    boundaries = np.zeros(labels.shape, dtype=bool)
    boundaries[1:] |= labels[1:] != labels[:-1]
    boundaries[:, 1:] |= labels[:, 1:] != labels[:, :-1]
    return boundaries


def prepare_review(bundle: Path, result_path: Path, out: Path) -> dict:
    """Render only after validating bundle identity, grid, units and field hashes.

    The reference window uses one fixed range from the complete cached atlas.
    Mapping that range to PNG bytes is explicitly a display operation; no
    per-section normalization, registration, or source-image warp occurs here.
    """
    from abba_bridge import BridgeBlocked, read_json, sha256, validate_result, write_json

    bundle, result_path, out = bundle.resolve(), result_path.resolve(), out.resolve()
    validate_result(bundle, result_path)
    manifest, result = read_json(bundle / "manifest.json"), read_json(result_path)
    state_path = result_path.parent / result["stateFile"]
    if not state_path.is_file():
        raise BridgeBlocked("Official ABBA state file is missing; review was not created.")
    if out.exists():
        raise BridgeBlocked("Choose a new review directory; an existing review is never overwritten.")
    project_path = (bundle / manifest["projectSnapshotFile"] if manifest.get("projectSnapshotFile")
                    else Path(manifest["projectPath"]))
    if sha256(project_path) != manifest["projectSHA256"]:
        raise BridgeBlocked("Source project snapshot changed; review was not created.")
    project = read_json(project_path)
    atlas_root = Path(project["atlasAssets"]["atlasRootPath"])
    metadata = read_json(atlas_root / "metadata.json")
    resolution = np.asarray(metadata["resolution"], dtype=np.float64)
    if (metadata["orientation"] != "asr" or not np.array_equal(resolution, [25, 25, 25])
            or metadata["version"] != manifest["atlas"]["version"]):
        raise BridgeBlocked("Cached atlas axes, voxel size or version differ from the official result.")
    reference = tifffile.imread(atlas_root / "reference.tiff")
    annotation = tifffile.imread(atlas_root / "annotation.tiff")
    if reference.shape != annotation.shape or list(reference.shape) != metadata["shape"]:
        raise BridgeBlocked("Cached atlas volume dimensions differ from its metadata.")
    atlas_min, atlas_max = float(reference.min()), float(reference.max())
    if atlas_max <= atlas_min:
        raise BridgeBlocked("Cached atlas reference has no displayable intensity range.")
    records = {record["id"]: record for record in project["slices"]}
    upper = (np.asarray(reference.shape) - 1)[:, None, None]
    out.mkdir(parents=True)
    slices = []
    for index, (source_entry, registered) in enumerate(zip(manifest["slices"], result["slices"], strict=True)):
        source = tifffile.imread(bundle / source_entry["structuralFile"])
        if source.dtype != np.uint8 or source.ndim != 2:
            raise BridgeBlocked("Review requires the exported scalar uint8 structural image.")
        field = tifffile.imread(result_path.parent / registered["atlasCoordinatesFile"])
        coordinates = field.astype(np.float64) / resolution[:, None, None]
        in_volume = ((coordinates >= 0) & (coordinates <= upper)).all(axis=0)
        sampled = ndimage.map_coordinates(reference, coordinates, output=np.float32, order=1,
                                           mode="constant", cval=0, prefilter=False)
        labels = ndimage.map_coordinates(annotation, coordinates, order=0,
                                          mode="constant", cval=0, prefilter=False)
        atlas_display = np.rint(np.clip((sampled - atlas_min) / (atlas_max - atlas_min), 0, 1) * 255).astype(np.uint8)
        boundaries = annotation_boundaries(labels)
        overlay = np.repeat(source[..., None], 3, axis=2)
        overlay[boundaries] = [255, 199, 57]
        histology_path = out / f"section_{index:04d}_histology.png"
        atlas_path = out / f"section_{index:04d}_atlas.png"
        overlay_path = out / f"section_{index:04d}_overlay.png"
        boundary_path = out / f"section_{index:04d}_boundaries.png"
        Image.fromarray(source).save(histology_path)
        Image.fromarray(atlas_display).save(atlas_path)
        Image.fromarray(overlay).save(overlay_path)
        Image.fromarray(np.where(boundaries, 35, 255).astype(np.uint8)).save(boundary_path)
        record = records[source_entry["sliceID"]]
        slices.append({
            "id": source_entry["sliceID"], "title": record.get("title", source_entry["sliceID"]),
            "histologyPath": str(histology_path), "atlasPath": str(atlas_path), "overlayPath": str(overlay_path),
            "boundaryPath": str(boundary_path), "width": source.shape[1], "height": source.shape[0],
            "sourceSHA256": source_entry["structuralSHA256"], "atlasCoordinatesSHA256": registered["atlasCoordinatesSHA256"],
            "atlasVolumeCoverage": float(in_volume.mean()), "anatomicalReview": "required",
        })
    review_path = out / "review.json"
    review = {
        "schemaVersion": 1, "status": "official_abba_review_ready", "projectID": manifest["projectID"],
        "stage": result["stage"], "resultPath": str(result_path), "statePath": str(state_path.resolve()),
        "bundlePath": str(bundle), "sourceResultSHA256": sha256(result_path),
        "atlas": manifest["atlas"], "atlasRootPath": str(atlas_root.resolve()),
        "coordinateFrame": "BRAINGLOBE_PHYSICAL_ASR_UM", "coordinateImageAxes": "CYX",
        "sampling": {"reference": "trilinear", "annotation": "nearest neighbour", "outOfVolume": 0},
        "displayWindow": {
            "histology": [0, 255], "atlas": [atlas_min, atlas_max],
            "atlasRangeSelection": "Single full-volume cached-atlas native intensity range, shared by every section",
            "atlasByteMapping": "round(clip((value - low) / (high - low), 0, 1) * 255)",
            "histologyByteMapping": "Exported scalar uint8 pixels preserved exactly",
        },
        "slices": slices,
        "messages": [
            "Official ABBA coordinates and source identity were validated. Anatomical review is required; no result is accepted automatically.",
            f"Histology uses unchanged 0-255 source bytes. Atlas preview uses one fixed {atlas_min:g}-{atlas_max:g} native-intensity display window for all sections.",
            "Gold lines are atlas region boundaries sampled in the original canonical section grid. PNGs are review images, not quantitative intensity exports.",
        ],
    }
    write_json(review_path, review)
    return {"status": review["status"], "projectID": manifest["projectID"], "stage": result["stage"],
            "outputDirectory": str(out), "reviewPath": str(review_path), "sliceCount": len(slices)}
