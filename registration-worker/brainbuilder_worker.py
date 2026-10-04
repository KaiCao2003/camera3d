#!/usr/bin/env python3
"""BrainBuilder's real Allen CCF registration and probe-track worker.

The Swift application owns file selection and review state.  This worker owns
scientific image processing.  It deliberately uses well-tested packages for
atlas access, registration, segmentation, robust fitting, and image I/O:

* BrainGlobe Atlas API for a versioned Allen CCFv3 atlas
* SimpleITK for physical-coordinate affine registration and transform files
* scikit-image/scikit-learn for masks, QC, and robust probe-track detection
* NumPy/SciPy/Pillow/tifffile for array and artifact I/O

Every command writes a typed JSON result.  A command is successful only when it
has produced the advertised artifacts; tool discovery alone is never treated
as success.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import os
import re
import shutil
import sys
import tempfile
import traceback
from dataclasses import dataclass
from datetime import datetime, timezone
from importlib.metadata import version as package_version
from pathlib import Path
from typing import Any, Iterable, Literal

import numpy as np
import SimpleITK as sitk
import tifffile
from brainglobe_atlasapi import BrainGlobeAtlas
from PIL import Image, ImageDraw
from pydantic import BaseModel, ConfigDict, Field, ValidationError
from scipy import ndimage, optimize
from skimage import (
    color,
    exposure,
    filters,
    measure,
    morphology,
    segmentation,
    transform,
)
from sklearn.linear_model import HuberRegressor


ATLAS_NAME = "allen_mouse_25um"
ATLAS_VERSION = "1.2"
WORKER_VERSION = "0.2.0"
RANDOM_SEED = 1234
DEEPSLICE_VERSION = package_version("deepslice")
PROJECT_SCHEMA_VERSION = 2
ATLAS_EXPORT_SCHEMA_VERSION = 2
PROBE_TRACKS_SCHEMA_VERSION = 2
BLIND_TRACK_REVIEW_SCHEMA_VERSION = 1
MAX_SLICE_TRACK_CANDIDATES = 32
MAX_RECONSTRUCTED_TRACKS = 128
TRACK_RANSAC_RESIDUAL_UM = 100.0


class WorkerBlocked(RuntimeError):
    """A recoverable missing-input or review-state condition."""


class AtlasContract(BaseModel):
    model_config = ConfigDict(extra="allow")

    id: str
    version: str
    voxelSizeMicrons: float = Field(gt=0, le=100)


class ChannelMappingContract(BaseModel):
    model_config = ConfigDict(extra="allow")

    channelIndex: int = Field(ge=0)
    name: str = Field(min_length=1)
    role: Literal["structural", "probeTrack", "signal", "ignored"]


class SliceContract(BaseModel):
    model_config = ConfigDict(extra="allow")

    id: str = Field(min_length=1)
    sourceImagePath: str = Field(min_length=1)
    pixelSizeMicrons: float | None = Field(default=None, ge=0.1, le=100)
    transformChain: dict[str, Any]
    qc: dict[str, Any]
    probeTrack: dict[str, Any] | None = None
    probeTrackCandidates: list[dict[str, Any]] | None = Field(
        default=None,
        max_length=MAX_SLICE_TRACK_CANDIDATES,
    )


class Brain3DReviewDispositionContract(BaseModel):
    """One explicit human disposition; suggestions never satisfy this contract."""

    model_config = ConfigDict(extra="forbid")

    id: str = Field(min_length=1, max_length=200)
    state: Literal[
        "exactShank",
        "insertionLevelAmbiguous",
        "observedUnmatched",
        "plannedNotObserved",
    ]
    trackId: str | None = Field(default=None, min_length=1, max_length=200)
    insertionSnapshotId: str | None = Field(default=None, min_length=1, max_length=200)
    shankId: str | None = Field(default=None, min_length=1, max_length=200)
    reviewerLabel: str = Field(min_length=1, max_length=200)
    reason: str = Field(min_length=1, max_length=1000)
    confirmedAt: datetime


class ProjectContract(BaseModel):
    model_config = ConfigDict(extra="allow")

    schemaVersion: int = Field(default=1, ge=1, le=PROJECT_SCHEMA_VERSION)
    id: str
    atlas: AtlasContract
    orientation: str
    pixelSizeMicrons: float | None = Field(default=None, ge=0.1, le=100)
    channelMappings: list[ChannelMappingContract]
    slices: list[SliceContract]
    sourceMode: Literal["montageSections", "numberedOverlays"]


class RegistrationConfig(BaseModel):
    histogram_bins: int = Field(default=50, ge=16)
    sampling_percentage: float = Field(default=0.30, gt=0, le=1)
    iterations: int = Field(default=50, ge=10, le=500)
    shrink_factors: tuple[int, ...] = (4, 2, 1)
    smoothing_sigmas: tuple[float, ...] = (2, 1, 0)
    random_seed: int = RANDOM_SEED


class CorrectionPoint(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)

    x: float = Field(ge=0)
    y: float = Field(ge=0)


class CorrectionLandmark(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: str = Field(min_length=1)
    atlasPoint: CorrectionPoint
    slicePoint: CorrectionPoint
    label: str = ""


class SliceCorrection(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)

    atlasAPMicrons: float = Field(ge=0)
    pitchDegrees: float = Field(gt=-80, lt=80)
    yawDegrees: float = Field(gt=-80, lt=80)
    landmarks: list[CorrectionLandmark] = Field(default_factory=list)


@dataclass
class AtlasData:
    name: str
    version: str
    reference: np.ndarray
    annotation: np.ndarray | None
    resolution: tuple[float, float, float]
    orientation: str
    structures: Any
    root_dir: Path

    def require_annotation(self) -> np.ndarray:
        if self.annotation is None:
            raise WorkerBlocked("Atlas annotations were not loaded for this operation.")
        return self.annotation


@dataclass
class PreparedImage:
    rgba: np.ndarray
    rgb: np.ndarray
    gray: np.ndarray
    mask: np.ndarray
    selection_domain: np.ndarray | None = None


@dataclass
class AtlasPlaneData:
    gray: np.ndarray
    mask: np.ndarray
    annotation: np.ndarray
    image: sitk.Image
    center_ap_index: int
    atlas_origin: np.ndarray
    atlas_u: np.ndarray
    atlas_v: np.ndarray
    width: int
    height: int
    spacing: tuple[float, float]

    def atlas_coordinate_for_physical_point(
        self, point: tuple[float, float], atlas: AtlasData
    ) -> np.ndarray:
        x_index = float(point[0]) / self.spacing[0]
        y_index = float(point[1]) / self.spacing[1]
        # QuickNII anchoring defines U/V over the full image width/height,
        # i.e. o + (x / width) * u + (y / height) * v.
        x_fraction = x_index / max(1, self.width)
        y_fraction = y_index / max(1, self.height)
        atlas_index = (
            self.atlas_origin + x_fraction * self.atlas_u + y_fraction * self.atlas_v
        )
        return atlas_index * np.asarray(atlas.resolution, dtype=np.float64)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def safe_name(value: str) -> str:
    sanitized = re.sub(r"[^A-Za-z0-9_.-]+", "-", value).strip("-.")
    return sanitized or "slice"


def quicknii_ras_to_brainglobe_asr(
    points: np.ndarray, atlas_shape: tuple[int, ...]
) -> np.ndarray:
    """Convert QuickNII RAS voxel coordinates to BrainGlobe ASR array indices.

    QuickNII uses a NIfTI-style origin at left/posterior/inferior.  The
    BrainGlobe Allen volume used here has its index origin at
    anterior/superior/right, so all three anatomical axes must be flipped as
    well as reordered from x/y/z to AP/SI/RL.
    """
    quicknii = np.asarray(points, dtype=np.float64)
    if quicknii.shape[0] != 3 or len(atlas_shape) != 3:
        raise WorkerBlocked(
            f"QuickNII conversion requires 3D coordinates and atlas shape; got {quicknii.shape}, {atlas_shape}."
        )
    return np.stack(
        [
            (atlas_shape[0] - 1) - quicknii[1],
            (atlas_shape[1] - 1) - quicknii[2],
            (atlas_shape[2] - 1) - quicknii[0],
        ],
        axis=0,
    )


def quicknii_ras_vector_to_brainglobe_asr(vector: np.ndarray) -> np.ndarray:
    quicknii = np.asarray(vector, dtype=np.float64)
    if quicknii.shape != (3,):
        raise WorkerBlocked(
            f"QuickNII direction vector must have shape (3,), got {quicknii.shape}."
        )
    return np.asarray([-quicknii[1], -quicknii[2], -quicknii[0]], dtype=np.float64)


def read_json(path: Path) -> dict[str, Any]:
    try:
        with path.open("r", encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise WorkerBlocked(
            f"Could not read project JSON at {path}: {error}"
        ) from error
    raw_schema = payload.get("schemaVersion", 1)
    if isinstance(raw_schema, bool) or not isinstance(raw_schema, int):
        raise WorkerBlocked("Registration project schemaVersion must be an integer.")
    if raw_schema < 1 or raw_schema > PROJECT_SCHEMA_VERSION:
        raise WorkerBlocked(
            f"Registration project schema {raw_schema} is unsupported; expected 1..{PROJECT_SCHEMA_VERSION}."
        )
    if raw_schema == 1:
        payload = json.loads(json.dumps(payload))
        for slice_record in payload.get("slices", []):
            if "probeTrackCandidates" not in slice_record:
                legacy = slice_record.get("probeTrack")
                slice_record["probeTrackCandidates"] = (
                    [legacy] if isinstance(legacy, dict) else []
                )
        payload["schemaVersion"] = PROJECT_SCHEMA_VERSION
    try:
        ProjectContract.model_validate(payload)
    except ValidationError as error:
        raise WorkerBlocked(
            f"Registration project does not match the worker contract: {error}"
        ) from error
    return payload


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True, allow_nan=False)
        handle.write("\n")


def write_json_atomic(path: Path, payload: Any) -> None:
    """Replace a JSON sidecar atomically so readers never observe partial data."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as handle:
            temporary_path = Path(handle.name)
            json.dump(payload, handle, indent=2, sort_keys=True, allow_nan=False)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def emit_progress(
    args: argparse.Namespace,
    stage: str,
    completed: int,
    total: int,
    message: str,
    *,
    slice_record: dict[str, Any] | None = None,
    failed: int = 0,
) -> None:
    progress_path = getattr(args, "progress_json", None)
    if progress_path is None:
        return
    write_json_atomic(
        progress_path,
        {
            "schemaVersion": 1,
            "command": str(args.command),
            "stage": stage,
            "completed": int(completed),
            "total": int(total),
            "failed": int(failed),
            "sliceID": str(slice_record.get("id")) if slice_record else None,
            "sliceTitle": str(slice_record.get("title") or slice_record.get("id"))
            if slice_record
            else None,
            "message": message,
            "updatedAt": utc_now(),
        },
    )


def require_montage_source(project: dict[str, Any]) -> None:
    if project.get("sourceMode") != "montageSections":
        raise WorkerBlocked(
            "Atlas registration requires montageSections; numbered acquisition tiles are preview-only."
        )


def hash_file(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def combined_checksum(values: dict[str, str]) -> str | None:
    """Hash a named set of hashes without depending on dictionary order."""
    if not values:
        return None
    digest = hashlib.sha256()
    for name, value in sorted(values.items()):
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(value.encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def canonical_json_sha256(value: Any) -> str:
    """Hash a JSON value with stable key/order/number formatting.

    This digest deliberately excludes whitespace and forbids non-finite values,
    so it is safe to use as an immutable blind-stage or prior receipt identity.
    """
    encoded = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def blind_registration_input_sha256(project: dict[str, Any]) -> str:
    """Hash an allowlisted blind scientific DTO, never post-hoc/UI context.

    In particular, loading, replacing, or locking a Brain3D handoff changes
    timestamps and review state in the native project.  None of those values
    may alter registration, 2-D candidate, or reconstructed-track identity.
    """

    allowed = (
        "schemaVersion",
        "datasetRootPath",
        "atlas",
        "orientation",
        "pixelSizeMicrons",
        "channelMappings",
        "slices",
        "atlasAssets",
        "sourceMode",
        "provenance",
    )
    scientific = {
        key: json.loads(json.dumps(project[key])) for key in allowed if key in project
    }
    return canonical_json_sha256(scientific)


def relative_export_path(root: Path, path: Path) -> str:
    """Return a portable POSIX path and reject accidental paths outside root."""
    try:
        relative = path.resolve().relative_to(root.resolve())
    except ValueError as error:
        raise WorkerBlocked(
            f"Export artifact escaped the destination folder: {path}"
        ) from error
    return relative.as_posix()


def copy_export_file(source: Path, destination: Path, root: Path) -> str:
    """Copy one export input and return its path relative to the export root."""
    if not source.is_file():
        raise WorkerBlocked(f"Required export input is missing: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    if source.resolve() != destination.resolve():
        shutil.copy2(source, destination)
    return relative_export_path(root, destination)


def result_envelope(
    command: str,
    stage: str,
    project: dict[str, Any] | None,
    output_path: Path | None,
    messages: list[str],
    *,
    slice_record: dict[str, Any] | None = None,
    export: dict[str, Any] | None = None,
    brain3d_review_preview: dict[str, Any] | None = None,
    blind_track_review_preview: dict[str, Any] | None = None,
) -> dict[str, Any]:
    return {
        "command": command,
        "stage": stage,
        "projectID": project.get("id") if project else None,
        "outputPath": str(output_path) if output_path else None,
        "messages": messages,
        "project": project,
        "slice": slice_record,
        "export": export,
        "brain3DReviewPreview": brain3d_review_preview,
        "blindTrackReviewPreview": blind_track_review_preview,
    }


def atlas_cache_root(project: dict[str, Any] | None = None) -> Path:
    configured = os.environ.get("BRAINBUILDER_ATLAS_HOME")
    if configured:
        return Path(configured).expanduser().resolve()
    if project:
        assets = project.get("atlasAssets") or {}
        if assets.get("cachePath"):
            return Path(assets["cachePath"]).expanduser().resolve()
    return (
        Path.home() / "Library" / "Application Support" / "BrainBuilder" / "BrainGlobe"
    )


def load_atlas(project: dict[str, Any], *, annotations: bool) -> AtlasData:
    assets = project.get("atlasAssets") or {}
    fixture_path = assets.get("fixturePath")
    if fixture_path:
        fixture = Path(fixture_path)
        if not fixture.is_file():
            raise WorkerBlocked(f"Synthetic atlas fixture does not exist: {fixture}")
        loaded = np.load(fixture, allow_pickle=False)
        reference = np.asarray(loaded["reference"])
        annotation = np.asarray(loaded["annotation"]) if annotations else None
        resolution_raw = loaded.get("resolution", np.asarray([25.0, 25.0, 25.0]))
        fixture_structures: dict[int, dict[str, Any]] = {}
        if annotation is not None:
            for structure_id in np.unique(annotation):
                value = int(structure_id)
                if value == 0:
                    continue
                fixture_structures[value] = {
                    "id": value,
                    "acronym": str(value),
                    "name": f"Fixture region {value}",
                    "rgb_triplet": [170, 170, 170],
                }
        return AtlasData(
            name="brainbuilder_fixture",
            version="test",
            reference=reference,
            annotation=annotation,
            resolution=tuple(float(value) for value in resolution_raw),
            orientation="asr",
            structures=fixture_structures,
            root_dir=fixture.parent,
        )

    descriptor = project.get("atlas") or {}
    atlas_name = descriptor.get("id", ATLAS_NAME)
    if atlas_name != ATLAS_NAME:
        raise WorkerBlocked(
            f"This worker supports {ATLAS_NAME}; project requested {atlas_name}. "
            "Recreate the project with the supported atlas descriptor."
        )

    cache = atlas_cache_root(project)
    cache.mkdir(parents=True, exist_ok=True)
    download_cache = cache / ".downloads"
    download_cache.mkdir(parents=True, exist_ok=True)
    # BrainGlobe 2.x expects config_dir to be a config *file* path.  Passing
    # both storage directories explicitly avoids dependence on global config.
    atlas = BrainGlobeAtlas(
        atlas_name,
        brainglobe_dir=cache / "atlases",
        interm_download_dir=download_cache,
        config_dir=cache / "brainbuilder-atlas-config.json",
        check_latest=False,
    )
    reference = np.asarray(atlas.reference)
    orientation = str(atlas.metadata.get("orientation", atlas.orientation)).lower()
    actual_version = str(atlas.metadata.get("version", ATLAS_VERSION))
    requested_version = str(descriptor.get("version", ATLAS_VERSION))
    if actual_version != requested_version:
        raise WorkerBlocked(
            f"Atlas version mismatch: project requires {requested_version}, cache provides {actual_version}."
        )
    if orientation != "asr" or tuple(atlas.space.axes_description) != (
        "ap",
        "si",
        "rl",
    ):
        raise WorkerBlocked(
            "Allen atlas orientation is not ASR/AP-SI-RL; refusing to guess coordinate axes."
        )
    resolution = tuple(float(value) for value in atlas.resolution)
    requested_voxel = float(descriptor.get("voxelSizeMicrons", 25.0))
    if any(abs(value - requested_voxel) > 1e-6 for value in resolution):
        raise WorkerBlocked(
            f"Atlas resolution mismatch: project requires {requested_voxel:g} um, cache provides {resolution}."
        )
    annotation = np.asarray(atlas.annotation) if annotations else None
    return AtlasData(
        name=atlas_name,
        version=actual_version,
        reference=reference,
        annotation=annotation,
        resolution=resolution,
        orientation=orientation,
        structures=atlas.structures,
        root_dir=Path(atlas.root_dir),
    )


def normalize_intensity(
    values: np.ndarray, mask: np.ndarray | None = None
) -> np.ndarray:
    values = np.asarray(values, dtype=np.float32)
    finite = np.isfinite(values)
    selection = finite if mask is None else finite & np.asarray(mask, dtype=bool)
    samples = values[selection]
    if samples.size < 16:
        return np.zeros_like(values, dtype=np.float32)
    low, high = np.percentile(samples, [1.0, 99.5])
    if not math.isfinite(float(low)) or not math.isfinite(float(high)) or high <= low:
        return np.zeros_like(values, dtype=np.float32)
    return exposure.rescale_intensity(
        values, in_range=(float(low), float(high)), out_range=(0.0, 1.0)
    ).astype(np.float32)


def largest_component(mask: np.ndarray) -> np.ndarray:
    labels = measure.label(mask, connectivity=2)
    if labels.max() == 0:
        return np.zeros_like(mask, dtype=bool)
    counts = np.bincount(labels.ravel())
    counts[0] = 0
    return labels == int(np.argmax(counts))


def major_components(
    mask: np.ndarray, minimum_relative_area: float = 0.02
) -> np.ndarray:
    """Keep the substantial pieces of one selected tissue section.

    A torn coronal section can contain two disconnected hemispheres, so reducing
    an authoritative app-provided alpha mask to only its largest component can
    silently discard valid anatomy. Tiny isolated alpha specks are still removed.
    """
    labels = measure.label(np.asarray(mask, dtype=bool), connectivity=2)
    if labels.max() == 0:
        return np.zeros_like(mask, dtype=bool)
    counts = np.bincount(labels.ravel())
    counts[0] = 0
    largest = int(counts.max())
    minimum = max(32, int(math.ceil(largest * minimum_relative_area)))
    retained = np.flatnonzero(counts >= minimum)
    return np.isin(labels, retained)


def tissue_mask(gray: np.ndarray, alpha: np.ndarray | None = None,
                selection_domain: np.ndarray | None = None) -> np.ndarray:
    gray = normalize_intensity(gray, selection_domain)
    candidates: list[np.ndarray] = []
    alpha_domain: np.ndarray | None = selection_domain
    if alpha is not None and float(np.max(alpha)) <= 0.05:
        # A prepared RGBA image with no selected-section pixels is invalid.
        # Falling back to grayscale here can turn transparent RGB residue into
        # an apparently valid whole-frame section and contaminate registration.
        raise WorkerBlocked(
            "The selected-section alpha mask is empty; prepare the section again."
        )
    if selection_domain is None and alpha is not None and float(np.ptp(alpha)) > 0.05:
        threshold = filters.threshold_otsu(alpha)
        alpha_domain = major_components(alpha >= threshold)
        coverage = float(alpha_domain.mean())
        if 0.02 <= coverage <= 0.98:
            # Alpha is the selected-section contract from the app, not another
            # segmentation hypothesis. Returning it directly prevents a brighter
            # neighboring section in the crop from winning the grayscale score.
            return alpha_domain.astype(bool)
    try:
        samples = gray if selection_domain is None else gray[selection_domain]
        candidates.append(gray >= filters.threshold_otsu(samples))
    except ValueError:
        pass

    best = np.zeros_like(gray, dtype=bool)
    best_score = -1.0
    for candidate in candidates:
        if alpha_domain is not None:
            candidate = np.logical_and(candidate, alpha_domain)
        minimum_size = max(32, candidate.size // 1000)
        candidate = morphology.remove_small_objects(
            candidate.astype(bool), max_size=minimum_size - 1, connectivity=2
        )
        candidate = morphology.closing(
            candidate, footprint=morphology.disk(max(2, min(candidate.shape) // 100))
        )
        candidate = ndimage.binary_fill_holes(candidate)
        candidate = major_components(candidate) if selection_domain is not None else largest_component(candidate)
        if alpha_domain is not None:
            candidate = np.logical_and(candidate, alpha_domain)
        coverage = float(candidate.mean())
        score = 1.0 - abs(coverage - 0.55)
        if 0.08 <= coverage <= 0.94 and score > best_score:
            best = candidate
            best_score = score

    if best_score < 0:
        samples = gray if selection_domain is None else gray[selection_domain]
        fallback = gray >= float(np.percentile(samples, 55.0))
        if alpha_domain is not None:
            fallback = np.logical_and(fallback, alpha_domain)
        filled = ndimage.binary_fill_holes(fallback)
        best = major_components(filled) if selection_domain is not None else largest_component(filled)
        if alpha_domain is not None:
            best = np.logical_and(best, alpha_domain)
    return best.astype(bool)


def raster_orientation(pose: dict[str, Any] | None) -> dict[str, Any]:
    """Return the discrete source-to-canonical raster orientation for a pose.

    DeepSlice orientation selection intentionally considers only 0 and 180
    degrees, but accepting all right-angle rotations keeps manually-authored
    poses deterministic.  Flips are applied in source coordinates before the
    counter-clockwise rotation.
    """
    pose = pose or {}
    raw_rotation = float(pose.get("rotationDegrees", 0.0))
    normalized = raw_rotation % 360.0
    right_angle = int(round(normalized / 90.0)) % 4
    snapped = float(right_angle * 90)
    circular_error = min(
        abs(normalized - snapped),
        abs(normalized - snapped - 360.0),
        abs(normalized - snapped + 360.0),
    )
    if circular_error > 1e-6:
        raise WorkerBlocked(
            f"Raster rotation {raw_rotation:g} degrees is unsupported; expected a multiple of 90 degrees."
        )
    return {
        "rotationDegrees": int(right_angle * 90),
        "flipHorizontal": bool(pose.get("flipHorizontal", False)),
        "flipVertical": bool(pose.get("flipVertical", False)),
    }


def orient_raster(values: np.ndarray, pose: dict[str, Any] | None) -> np.ndarray:
    """Map a source raster into the canonical slice pixel coordinate space."""
    orientation = raster_orientation(pose)
    oriented = np.asarray(values)
    if orientation["flipHorizontal"]:
        oriented = np.flip(oriented, axis=1)
    if orientation["flipVertical"]:
        oriented = np.flip(oriented, axis=0)
    quarter_turns = int(orientation["rotationDegrees"]) // 90
    if quarter_turns:
        oriented = np.rot90(oriented, k=quarter_turns, axes=(0, 1))
    return np.ascontiguousarray(oriented)


def load_oriented_rgba(path: Path, pose: dict[str, Any] | None = None) -> np.ndarray:
    if not path.is_file():
        raise WorkerBlocked(f"Prepared slice image is missing: {path}")
    with Image.open(path) as source:
        rgba = np.asarray(source.convert("RGBA"))
    return orient_raster(rgba, pose)


def load_prepared_image(
    path: Path, pose: dict[str, Any] | None = None,
    selection_mask_path: Path | None = None,
) -> PreparedImage:
    if not path.is_file():
        raise WorkerBlocked(f"Prepared slice image is missing: {path}")
    rgba = load_oriented_rgba(path, pose)
    selection_domain = None
    if selection_mask_path is not None:
        if not selection_mask_path.is_file():
            raise WorkerBlocked(f"Selection-domain mask is missing: {selection_mask_path}")
        with Image.open(selection_mask_path) as image:
            selection_domain = orient_raster(np.asarray(image.convert("L")) > 0, pose)
        if selection_domain.shape != rgba.shape[:2] or not selection_domain.any():
            raise WorkerBlocked("Selection-domain mask is empty or differs from the source image grid.")
        # Selection is a geometric domain, not display opacity or tissue signal.
        rgb = rgba[..., :3].astype(np.float32) / 255.0
        rgb[~selection_domain] = 0
        alpha = None
    else:
        alpha = rgba[..., 3].astype(np.float32) / 255.0
        rgb = color.rgba2rgb(rgba, background=(0, 0, 0)).astype(np.float32)
    gray = color.rgb2gray(rgb).astype(np.float32)
    mask = tissue_mask(gray, alpha, selection_domain)
    gray = normalize_intensity(gray, mask)
    return PreparedImage(rgba=rgba, rgb=rgb, gray=gray, mask=mask, selection_domain=selection_domain)


def artifact_record(slice_record: dict[str, Any]) -> dict[str, Any]:
    artifacts = slice_record.setdefault("artifacts", {})
    defaults = {
        "preparedImagePath": slice_record.get("sourceImagePath"),
        "structuralImagePath": slice_record.get("sourceImagePath"),
        "probeChannelImagePath": None,
        "sourceOverlayImagePath": None,
        "rawStructuralImagePath": None,
        "rawProbeChannelImagePath": None,
        "rawSourceOverlayImagePath": None,
        "selectionMaskPath": None,
        "rawSelectionMaskPath": None,
        "tissueMaskPath": None,
        "atlasReferencePath": None,
        "registeredImagePath": None,
        "overlayImagePath": None,
        "boundaryImagePath": None,
        "checkerboardImagePath": None,
        "differenceImagePath": None,
        "annotationImagePath": None,
        "transformPath": None,
        "trackMaskPath": None,
        "trackOverlayPath": None,
    }
    for key, value in defaults.items():
        artifacts.setdefault(key, value)
    return artifacts


def source_raster_path(slice_record: dict[str, Any], role: str) -> Path | None:
    """Resolve the immutable raw raster for an aligned registration channel."""
    artifacts = artifact_record(slice_record)
    if role == "structural":
        values = (
            artifacts.get("rawStructuralImagePath"),
            slice_record.get("sourceImagePath"),
            artifacts.get("structuralImagePath"),
        )
    elif role == "probe":
        values = (
            artifacts.get("rawProbeChannelImagePath"),
            artifacts.get("probeChannelImagePath"),
        )
    elif role == "sourceOverlay":
        values = (
            artifacts.get("rawSourceOverlayImagePath"),
            artifacts.get("sourceOverlayImagePath"),
        )
    elif role == "selectionMask":
        values = (artifacts.get("rawSelectionMaskPath"), artifacts.get("selectionMaskPath"))
    else:
        raise ValueError(f"Unknown raster role: {role}")
    for value in values:
        if value:
            return Path(str(value)).expanduser()
    if role == "sourceOverlay":
        structural = source_raster_path(slice_record, "structural")
        if structural is not None:
            sibling = structural.with_name("source-overlay.png")
            if sibling.is_file():
                return sibling
    return None


def verify_selection_mask_identity(project: dict[str, Any], slice_record: dict[str, Any]) -> None:
    expected = (project.get("provenance") or {}).get("selectionMaskHashes")
    mask_path = source_raster_path(slice_record, "selectionMask")
    if expected is not None and (mask_path is not None or str(slice_record["id"]) in expected):
        if mask_path is None or hash_file(mask_path) != expected.get(str(slice_record["id"])):
            raise WorkerBlocked(f"Selection-domain mask changed for {slice_record['id']}; prepare and estimate the source again.")


def materialize_oriented_source_artifacts(
    slice_record: dict[str, Any],
    prepared: PreparedImage,
    slice_dir: Path,
) -> None:
    """Write every aligned input raster in the pose's canonical pixel space.

    Raw paths remain available for a later orientation change, while affine and
    probe coordinates explicitly refer to these canonical artifacts.
    """
    pose = slice_record.get("pose") or {}
    orientation = raster_orientation(pose)
    artifacts = artifact_record(slice_record)
    slice_dir.mkdir(parents=True, exist_ok=True)

    raw_structural = source_raster_path(slice_record, "structural")
    if raw_structural is None or not raw_structural.is_file():
        raise WorkerBlocked(
            f"Structural channel image is missing for {slice_record.get('id')}."
        )
    artifacts["rawStructuralImagePath"] = str(raw_structural.resolve())
    structural_path = slice_dir / "canonical-structural.png"
    Image.fromarray(prepared.rgba, mode="RGBA").save(structural_path)
    artifacts["preparedImagePath"] = str(structural_path)
    artifacts["structuralImagePath"] = str(structural_path)
    if prepared.selection_domain is not None:
        raw_selection = source_raster_path(slice_record, "selectionMask")
        artifacts["rawSelectionMaskPath"] = str(raw_selection.resolve())
        selection_path = slice_dir / "canonical-selection-mask.png"
        save_mask(selection_path, prepared.selection_domain)
        artifacts["selectionMaskPath"] = str(selection_path)

    raw_probe = source_raster_path(slice_record, "probe")
    if raw_probe is not None:
        if not raw_probe.is_file():
            raise WorkerBlocked(
                f"Probe channel image is missing for {slice_record.get('id')}: {raw_probe}"
            )
        probe_rgba = load_oriented_rgba(raw_probe, pose)
        if probe_rgba.shape[:2] != prepared.rgba.shape[:2]:
            raise WorkerBlocked(
                f"Probe/structural channel dimensions differ for {slice_record.get('id')}: "
                f"probe={probe_rgba.shape[:2]}, structural={prepared.rgba.shape[:2]}."
            )
        artifacts["rawProbeChannelImagePath"] = str(raw_probe.resolve())
        probe_path = slice_dir / "canonical-probe-channel.png"
        Image.fromarray(probe_rgba, mode="RGBA").save(probe_path)
        artifacts["probeChannelImagePath"] = str(probe_path)

    raw_overlay = source_raster_path(slice_record, "sourceOverlay")
    if raw_overlay is not None:
        if not raw_overlay.is_file():
            raise WorkerBlocked(
                f"Source overlay image is missing for {slice_record.get('id')}: {raw_overlay}"
            )
        overlay_rgba = load_oriented_rgba(raw_overlay, pose)
        if overlay_rgba.shape[:2] != prepared.rgba.shape[:2]:
            raise WorkerBlocked(
                f"Source-overlay/structural dimensions differ for {slice_record.get('id')}: "
                f"overlay={overlay_rgba.shape[:2]}, structural={prepared.rgba.shape[:2]}."
            )
        artifacts["rawSourceOverlayImagePath"] = str(raw_overlay.resolve())
        overlay_path = slice_dir / "canonical-source-overlay.png"
        Image.fromarray(overlay_rgba, mode="RGBA").save(overlay_path)
        artifacts["sourceOverlayImagePath"] = str(overlay_path)

    mask_path = slice_dir / "tissue-mask.png"
    save_mask(mask_path, prepared.mask)
    artifacts["tissueMaskPath"] = str(mask_path)
    slice_record["imageSize"] = {
        "width": int(prepared.gray.shape[1]),
        "height": int(prepared.gray.shape[0]),
    }
    slice_record["canonicalRasterOrientation"] = orientation


def save_mask(path: Path, mask: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray((mask.astype(np.uint8) * 255), mode="L").save(path)


def prepare_project(project: dict[str, Any], out: Path) -> dict[str, Any]:
    require_montage_source(project)
    out.mkdir(parents=True, exist_ok=True)
    slice_ids = [str(item.get("id", "")) for item in project.get("slices", [])]
    if len(slice_ids) != len(set(slice_ids)):
        raise WorkerBlocked("Registration slice IDs must be unique.")
    safe_ids = [safe_name(value) for value in slice_ids]
    if len(safe_ids) != len(set(safe_ids)):
        raise WorkerBlocked(
            "Registration slice IDs collide after filesystem-safe normalization."
        )
    project_pixel_size = project.get("pixelSizeMicrons")
    if project_pixel_size is None or not 0.1 <= float(project_pixel_size) <= 100.0:
        raise WorkerBlocked(
            "Project physical pixel size must be within 0.1..100 um/px."
        )
    structural_count = sum(
        item.get("role") == "structural" for item in project.get("channelMappings", [])
    )
    probe_count = sum(
        item.get("role") == "probeTrack" for item in project.get("channelMappings", [])
    )
    if structural_count != 1:
        raise WorkerBlocked(
            f"Registration requires exactly one structural channel; found {structural_count}."
        )
    if probe_count > 1:
        raise WorkerBlocked(
            f"Registration supports at most one probe-track channel; found {probe_count}."
        )
    seen_paths: set[Path] = set()
    source_hashes: dict[str, str] = {}
    selection_hashes: dict[str, str] = {}
    missing: list[str] = []
    duplicate_count = 0

    for slice_record in project.get("slices", []):
        slice_pixel_size = slice_record.get("pixelSizeMicrons")
        if slice_pixel_size is None or not 0.1 <= float(slice_pixel_size) <= 100.0:
            raise WorkerBlocked(
                f"{slice_record.get('id')} is missing a valid per-section pixel calibration (0.1..100 um/px)."
            )
        image_path = Path(slice_record.get("sourceImagePath", "")).expanduser()
        if not image_path.is_file():
            missing.append(f"{slice_record.get('id')}: {image_path}")
            continue
        resolved = image_path.resolve()
        if resolved in seen_paths:
            duplicate_count += 1
        seen_paths.add(resolved)

        selection_path = source_raster_path(slice_record, "selectionMask")
        prepared = load_prepared_image(resolved, selection_mask_path=selection_path)
        if selection_path is not None:
            selection_hashes[str(slice_record["id"])] = hash_file(selection_path)
        slice_dir = out / "slices" / safe_name(str(slice_record.get("id", "slice")))
        mask_path = slice_dir / "tissue-mask.png"
        save_mask(mask_path, prepared.mask)
        artifacts = artifact_record(slice_record)
        probe_value = artifacts.get("probeChannelImagePath")
        if probe_value:
            probe_path = Path(probe_value).expanduser()
            if not probe_path.is_file():
                raise WorkerBlocked(
                    f"Probe channel image is missing for {slice_record.get('id')}: {probe_path}"
                )
            probe = load_prepared_image(probe_path, selection_mask_path=selection_path)
            if probe.gray.shape != prepared.gray.shape:
                raise WorkerBlocked(
                    f"Probe/structural channel dimensions differ for {slice_record.get('id')}: "
                    f"probe={probe.gray.shape}, structural={prepared.gray.shape}."
                )
        artifacts["preparedImagePath"] = str(resolved)
        artifacts["structuralImagePath"] = str(resolved)
        artifacts["tissueMaskPath"] = str(mask_path)
        slice_record["imageSize"] = {
            "width": int(prepared.gray.shape[1]),
            "height": int(prepared.gray.shape[0]),
        }
        slice_record["status"] = "prepared"
        digest = hash_file(resolved)
        if digest:
            source_hashes[str(slice_record.get("id"))] = digest

    if missing:
        raise WorkerBlocked("Prepared images are missing: " + "; ".join(missing[:5]))
    if duplicate_count:
        raise WorkerBlocked(
            f"{duplicate_count} logical slice(s) still share the same raster. "
            "Materialize one cropped registration image per section before running the worker."
        )
    if not project.get("slices"):
        raise WorkerBlocked("The registration project has no tissue sections.")

    project["updatedAt"] = utc_now()
    project.setdefault("provenance", {})["sourceImageHashes"] = source_hashes
    if selection_hashes:
        project["provenance"]["selectionMaskHashes"] = selection_hashes
    project["provenance"]["workerVersion"] = WORKER_VERSION
    output = out / "project.json"
    write_json(output, project)
    write_json(
        out / "prepare-manifest.json",
        {
            "preparedAt": utc_now(),
            "sliceCount": len(project.get("slices", [])),
            "uniqueRasterCount": len(seen_paths),
            "sourceImageHashes": source_hashes,
            "selectionMaskHashes": selection_hashes,
            "workerVersion": WORKER_VERSION,
        },
    )
    return result_envelope(
        "prepare",
        "ok",
        project,
        output,
        [f"Prepared {len(seen_paths)} unique section raster(s) and tissue masks."],
    )


def fit_mask_canvas(
    mask: np.ndarray, shape: tuple[int, int] = (96, 128)
) -> tuple[np.ndarray, float]:
    coordinates = np.argwhere(mask)
    if coordinates.size == 0:
        return np.zeros(shape, dtype=bool), 0.0
    y0, x0 = coordinates.min(axis=0)
    y1, x1 = coordinates.max(axis=0) + 1
    cropped = mask[y0:y1, x0:x1]
    aspect = float(cropped.shape[1]) / float(max(1, cropped.shape[0]))
    scale = min(shape[0] / cropped.shape[0], shape[1] / cropped.shape[1])
    target_h = max(1, int(round(cropped.shape[0] * scale)))
    target_w = max(1, int(round(cropped.shape[1] * scale)))
    resized = (
        transform.resize(
            cropped.astype(np.float32),
            (target_h, target_w),
            order=0,
            preserve_range=True,
            anti_aliasing=False,
        )
        >= 0.5
    )
    canvas = np.zeros(shape, dtype=bool)
    y = (shape[0] - target_h) // 2
    x = (shape[1] - target_w) // 2
    canvas[y : y + target_h, x : x + target_w] = resized
    return canvas, aspect


def dice_score(lhs: np.ndarray, rhs: np.ndarray) -> float:
    denominator = int(lhs.sum()) + int(rhs.sum())
    return (
        1.0
        if denominator == 0
        else 2.0 * float(np.logical_and(lhs, rhs).sum()) / denominator
    )


def monotonic_path(
    scores: np.ndarray, *, max_jump: int = 18
) -> tuple[np.ndarray, float]:
    rows, columns = scores.shape
    dp = np.full((rows, columns), -np.inf, dtype=np.float64)
    previous = np.full((rows, columns), -1, dtype=np.int32)
    dp[0] = scores[0]
    preferred_jump = 2
    for row in range(1, rows):
        for column in range(columns):
            start = max(0, column - max_jump)
            for prior in range(start, column):
                gap = column - prior
                value = dp[row - 1, prior] - 0.012 * abs(gap - preferred_jump)
                if value > dp[row, column]:
                    dp[row, column] = value + scores[row, column]
                    previous[row, column] = prior
    end = int(np.argmax(dp[-1]))
    if not math.isfinite(float(dp[-1, end])):
        raise WorkerBlocked(
            "Could not find a monotonic AP sequence for the supplied sections."
        )
    path = np.zeros(rows, dtype=np.int32)
    path[-1] = end
    for row in range(rows - 1, 0, -1):
        path[row - 1] = previous[row, path[row]]
    return path, float(dp[-1, end] / rows)


def pose_silhouette_score(prepared: PreparedImage, atlas_mask: np.ndarray) -> float:
    hist_mask, hist_aspect = fit_mask_canvas(prepared.mask)
    candidate_mask, candidate_aspect = fit_mask_canvas(atlas_mask)
    overlap = dice_score(hist_mask, candidate_mask)
    aspect_score = math.exp(
        -abs(math.log(max(hist_aspect, 1e-6) / max(candidate_aspect, 1e-6)))
    )
    return float(0.78 * overlap + 0.22 * aspect_score)


def dorsal_upright_score(mask: np.ndarray) -> float:
    """Score the coronal dorsal-up prior from the tissue silhouette.

    In a canonical coronal mouse section the dorsal quarter is typically wider
    than the ventral quarter.  A robust group median makes this a weak anatomy
    prior rather than a per-section hard rule; a 180-degree rotation negates it.
    """
    coordinates = np.argwhere(mask)
    if coordinates.size == 0:
        return 0.0
    y0, x0 = coordinates.min(axis=0)
    y1, x1 = coordinates.max(axis=0) + 1
    cropped = np.asarray(mask[y0:y1, x0:x1], dtype=bool)
    if cropped.shape[0] < 4 or cropped.shape[1] < 2:
        return 0.0
    widths = cropped.sum(axis=1).astype(np.float64)
    quarter = max(1, cropped.shape[0] // 4)
    top = float(np.mean(widths[:quarter]))
    bottom = float(np.mean(widths[-quarter:]))
    return float(np.clip((top - bottom) / max(top + bottom, 1.0), -1.0, 1.0))


def slicing_angles_from_anchoring(anchoring: np.ndarray) -> dict[str, float]:
    u = anchoring[3:6]
    v = anchoring[6:9]
    normal = np.cross(u, v)
    norm = float(np.linalg.norm(normal))
    if norm <= 1e-9:
        return {"pitchDegrees": 0.0, "rollDegrees": 0.0, "yawDegrees": 0.0}
    normal /= norm
    if normal[1] < 0:
        normal *= -1
    return {
        "pitchDegrees": float(
            math.degrees(math.atan2(normal[2], max(abs(normal[1]), 1e-9)))
        ),
        "rollDegrees": float(
            math.degrees(math.atan2(normal[0], max(abs(normal[1]), 1e-9)))
        ),
        "yawDegrees": 0.0,
    }


def corrected_pose(
    pose: dict[str, Any], correction: SliceCorrection, atlas: AtlasData
) -> dict[str, Any]:
    """Rotate the actual QuickNII plane about the atlas center axis.

    AP is measured at QuickNII x=RL/2, z=SI/2, as in DeepSlice's brain-center
    depth calculation. The UI's left/right tilt (yaw) is the legacy serialized
    ``rollDegrees`` normal slope; raster orientation is independent.
    """
    shape = atlas.reference.shape
    if correction.atlasAPMicrons > (shape[0] - 1) * atlas.resolution[0]:
        raise WorkerBlocked("Corrected AP position is outside the atlas.")
    anchoring_raw = pose.get("atlasAnchoring")
    if anchoring_raw is None:
        ap_index = float(pose["atlasAPMicrons"]) / atlas.resolution[0]
        anchoring = np.asarray(
            [shape[2] - 1, shape[0] - 1 - ap_index, shape[1] - 1,
             -shape[2], 0, 0, 0, 0, -shape[1]], dtype=np.float64
        )
    else:
        anchoring = np.asarray(anchoring_raw, dtype=np.float64)
    if anchoring.shape != (9,) or not np.all(np.isfinite(anchoring)):
        raise WorkerBlocked("Manual correction requires finite QuickNII anchoring.")
    origin, u, v = anchoring[:3], anchoring[3:6], anchoring[6:9]
    normal = np.cross(u, v)
    norm = float(np.linalg.norm(normal))
    if norm < 1e-9 or abs(float(normal[1])) / norm < 1e-6:
        raise WorkerBlocked("Manual coronal correction requires a non-degenerate coronal plane.")
    normal /= norm
    if normal[1] < 0:
        normal *= -1
    center = np.asarray([shape[2] / 2, 0.0, shape[1] / 2])
    center[1] = origin[1] - (
        normal[0] * (center[0] - origin[0])
        + normal[2] * (center[2] - origin[2])
    ) / normal[1]
    target_normal = np.asarray(
        [math.tan(math.radians(correction.yawDegrees)), 1.0,
         math.tan(math.radians(correction.pitchDegrees))]
    )
    target_normal /= np.linalg.norm(target_normal)
    cross = np.cross(normal, target_normal)
    cosine = float(np.dot(normal, target_normal))
    skew = np.asarray(
        [[0, -cross[2], cross[1]], [cross[2], 0, -cross[0]],
         [-cross[1], cross[0], 0]]
    )
    rotation = np.eye(3) + skew + (skew @ skew) / (1 + cosine)
    target_center = center.copy()
    target_center[1] = shape[0] - 1 - correction.atlasAPMicrons / atlas.resolution[0]
    updated_anchoring = np.concatenate(
        [target_center + rotation @ (origin - center), rotation @ u, rotation @ v]
    )
    updated = dict(pose)
    updated.update(
        atlasAPMicrons=correction.atlasAPMicrons,
        atlasAnchoring=updated_anchoring.tolist(),
        atlasSlicingAngles=slicing_angles_from_anchoring(updated_anchoring),
        manuallyLocked=True,
        provenance=(
            "Manual atlas plane correction; AP at atlas center axis; "
            f"pitch={correction.pitchDegrees:g} degrees; "
            f"left/right tilt={correction.yawDegrees:g} degrees; "
            "source raster orientation and plane extents retained."
        ),
    )
    return updated


def montage_group_key(slice_record: dict[str, Any]) -> str:
    group_id = str(slice_record.get("groupID") or "").strip()
    if group_id:
        return group_id
    slice_id = str(slice_record.get("id") or "")
    prefix, separator, _ = slice_id.partition("-montage-")
    return prefix if separator and prefix else slice_id


def select_group_orientations(
    slices: list[dict[str, Any]],
    candidate_depths: dict[tuple[str, int], float],
    candidate_upright_scores: dict[tuple[str, int], float] | None = None,
) -> dict[str, int]:
    """Choose one 0/180 orientation per montage using serial continuity.

    The dynamic program evaluates both possible AP directions.  Its dominant
    term is total variation between group-median DeepSlice depths; a smaller
    within-group dispersion term rejects orientations that make one montage
    internally incoherent.  Exact ties preserve the source orientation.
    """
    if not slices:
        return {}
    group_order: list[str] = []
    grouped_ids: dict[str, list[str]] = {}
    locked: dict[str, int] = {}
    for slice_record in slices:
        group = montage_group_key(slice_record)
        if group not in grouped_ids:
            group_order.append(group)
            grouped_ids[group] = []
        slice_id = str(slice_record.get("id"))
        grouped_ids[group].append(slice_id)
        pose = slice_record.get("pose") or {}
        if pose.get("manuallyLocked") is True:
            rotation = int(raster_orientation(pose)["rotationDegrees"])
            if rotation not in (0, 180):
                continue
            prior = locked.get(group)
            if prior is not None and prior != rotation:
                raise WorkerBlocked(
                    f"Montage {group} contains conflicting manually locked orientations."
                )
            locked[group] = rotation

    candidate_upright_scores = candidate_upright_scores or {}
    summaries: dict[tuple[str, int], tuple[float, float, float]] = {}
    for group in group_order:
        for rotation in (0, 180):
            values = np.asarray(
                [
                    candidate_depths[(slice_id, rotation)]
                    for slice_id in grouped_ids[group]
                ],
                dtype=np.float64,
            )
            if values.size == 0 or not np.all(np.isfinite(values)):
                raise WorkerBlocked(
                    f"DeepSlice returned invalid {rotation}-degree candidates for montage {group}."
                )
            median = float(np.median(values))
            dispersion = float(np.median(np.abs(values - median)))
            upright = float(
                np.median(
                    [
                        candidate_upright_scores.get((slice_id, rotation), 0.0)
                        for slice_id in grouped_ids[group]
                    ]
                )
            )
            summaries[(group, rotation)] = (median, dispersion, upright)

    all_medians = np.asarray(
        [summary[0] for summary in summaries.values()], dtype=np.float64
    )
    depth_scale = max(1.0, float(np.ptp(all_medians)))

    solutions: list[tuple[float, int, tuple[int, ...], dict[str, int]]] = []
    for direction in (-1, 1):
        states: dict[int, tuple[float, tuple[int, ...]]] = {}
        first = group_order[0]
        for rotation in (0, 180):
            if first in locked and locked[first] != rotation:
                continue
            _, dispersion, upright = summaries[(first, rotation)]
            states[rotation] = (
                0.25 * dispersion / depth_scale - 0.45 * upright,
                (rotation,),
            )

        for group_index in range(1, len(group_order)):
            prior_group = group_order[group_index - 1]
            group = group_order[group_index]
            next_states: dict[int, tuple[float, tuple[int, ...]]] = {}
            for rotation in (0, 180):
                if group in locked and locked[group] != rotation:
                    continue
                median, dispersion, upright = summaries[(group, rotation)]
                candidates: list[tuple[float, int, tuple[int, ...]]] = []
                for prior_rotation, (prior_cost, prior_path) in states.items():
                    prior_median, _, _ = summaries[(prior_group, prior_rotation)]
                    delta = median - prior_median
                    transition = (
                        abs(delta) + 2.0 * max(0.0, -direction * delta)
                    ) / depth_scale
                    path = (*prior_path, rotation)
                    candidates.append(
                        (
                            prior_cost
                            + transition
                            + 0.25 * dispersion / depth_scale
                            - 0.45 * upright,
                            path.count(180),
                            path,
                        )
                    )
                if candidates:
                    cost, _, path = min(candidates)
                    next_states[rotation] = (cost, path)
            states = next_states

        for cost, path in states.values():
            mapping = dict(zip(group_order, path, strict=True))
            solutions.append((cost, path.count(180), path, mapping))

    if not solutions:
        raise WorkerBlocked(
            "Could not choose a consistent source orientation for the montage sequence."
        )
    return min(solutions, key=lambda item: (item[0], item[1], item[2]))[-1]


def enforce_monotonic_brain_center_depths(
    predictions: Any,
    calculate_depths: Any,
) -> Any:
    """Make final QuickNII brain-center depths monotonic in section order.

    DeepSlice's index helper permutes only ``oy``. After angle propagation,
    differing U/V extents can therefore leave small center-depth reversals.
    Translating each plane along RAS Y preserves its angle and exactly restores
    the sorted center-depth distribution.
    """
    if len(predictions) < 2:
        return predictions
    output = predictions.copy().reset_index(drop=True)
    depths = np.asarray(calculate_depths(output), dtype=np.float64)
    if not np.all(np.isfinite(depths)):
        raise WorkerBlocked("DeepSlice returned non-finite final brain-center depths.")
    differences = np.diff(depths)
    direction = float(np.median(differences))
    if abs(direction) <= 1e-9:
        direction = float(depths[-1] - depths[0])
    ascending = direction >= 0.0
    targets = np.sort(depths)
    if not ascending:
        targets = targets[::-1]
    output["oy"] = output["oy"].astype(float) + (targets - depths)
    corrected = np.asarray(calculate_depths(output), dtype=np.float64)
    tolerance = 1e-6
    if ascending and np.any(np.diff(corrected) < -tolerance):
        raise WorkerBlocked("Could not enforce ascending DeepSlice brain-center order.")
    if not ascending and np.any(np.diff(corrected) > tolerance):
        raise WorkerBlocked(
            "Could not enforce descending DeepSlice brain-center order."
        )
    output["depths"] = corrected
    return output


def install_pose(
    slice_record: dict[str, Any],
    pose: dict[str, Any],
    *,
    engine: str,
) -> None:
    """Install a new atlas plane and invalidate every downstream artifact."""
    previous_pose = slice_record.get("pose")
    previous_orientation = (
        raster_orientation(previous_pose) if previous_pose else raster_orientation(None)
    )
    next_orientation = raster_orientation(pose)
    slice_record["pose"] = pose
    slice_record["status"] = "poseEstimated"
    chain = slice_record.setdefault("transformChain", {})
    chain["direction"] = "atlasToSlice"
    chain["transforms"] = [pose_transform(pose, engine=engine)]
    artifacts = artifact_record(slice_record)
    if previous_orientation != next_orientation:
        raw_structural = artifacts.get("rawStructuralImagePath") or slice_record.get(
            "sourceImagePath"
        )
        raw_probe = artifacts.get("rawProbeChannelImagePath") or artifacts.get(
            "probeChannelImagePath"
        )
        raw_overlay = artifacts.get("rawSourceOverlayImagePath") or artifacts.get(
            "sourceOverlayImagePath"
        )
        artifacts["preparedImagePath"] = raw_structural
        artifacts["structuralImagePath"] = raw_structural
        artifacts["probeChannelImagePath"] = raw_probe
        artifacts["sourceOverlayImagePath"] = raw_overlay
        artifacts["selectionMaskPath"] = artifacts.get("rawSelectionMaskPath") or artifacts.get("selectionMaskPath")
        artifacts["tissueMaskPath"] = None
        slice_record.pop("canonicalRasterOrientation", None)
    for key in (
        "atlasReferencePath",
        "registeredImagePath",
        "overlayImagePath",
        "boundaryImagePath",
        "checkerboardImagePath",
        "differenceImagePath",
        "annotationImagePath",
        "transformPath",
        "trackMaskPath",
        "trackOverlayPath",
        "atlasAPIndex",
    ):
        artifacts[key] = None
    slice_record["probeTrack"] = None
    slice_record["probeTrackCandidates"] = []
    qc = slice_record.setdefault("qc", {})
    qc["majorRegionIoU"] = None
    qc["mutualInformationMetric"] = None
    qc["landmarkRMSErrorMicrons"] = None
    for key in ("rawPoseAPMicrons", "orderedPoseAPMicrons", "poseAdjustmentMicrons"):
        qc[key] = None
    qc["warnings"] = [
        warning for warning in qc.get("warnings", [])
        if not warning.startswith(("DeepSlice pose adjustment", "Manual landmark fit"))
    ]
    slice_record["reviewNotes"] = (
        "Pose changed; affine registration and probe mapping must be recomputed."
    )


def estimate_poses_with_deepslice(
    project: dict[str, Any], atlas: AtlasData, out: Path
) -> dict[str, Any]:
    from DeepSlice import DSModel
    from DeepSlice.coord_post_processing.depth_estimation import (
        calculate_brain_center_depths,
    )

    slices = project.get("slices", [])
    out.mkdir(parents=True, exist_ok=True)
    filename_to_candidate: dict[str, tuple[dict[str, Any], int]] = {}
    candidate_upright_scores: dict[tuple[str, int], float] = {}
    with tempfile.TemporaryDirectory(prefix="brainbuilder-deepslice-") as temporary:
        input_dir = Path(temporary)
        candidate_number = 1
        for slice_record in slices:
            source = source_raster_path(slice_record, "structural")
            if source is None or not source.is_file():
                raise WorkerBlocked(
                    f"DeepSlice input is missing for {slice_record.get('id')}: {source}"
                )
            existing_pose = slice_record.get("pose") or {}
            for rotation in (0, 180):
                candidate_pose = {
                    "rotationDegrees": rotation,
                    "flipHorizontal": bool(existing_pose.get("flipHorizontal", False)),
                    "flipVertical": bool(existing_pose.get("flipVertical", False)),
                }
                filename = f"brainbuilder_r{rotation:03d}_s{candidate_number:04d}.png"
                destination = input_dir / filename
                candidate_prepared = load_prepared_image(source, candidate_pose, source_raster_path(slice_record, "selectionMask"))
                # RGBA.convert('RGB') drops alpha without applying it, exposing
                # neighboring raw tissue outside an explicit selection domain.
                deepslice_rgb = (np.rint(candidate_prepared.rgb * 255).astype(np.uint8)
                                 if candidate_prepared.selection_domain is not None else candidate_prepared.rgba[..., :3])
                Image.fromarray(deepslice_rgb, mode="RGB").save(destination)
                filename_to_candidate[filename] = (slice_record, rotation)
                candidate_upright_scores[(str(slice_record.get("id")), rotation)] = (
                    dorsal_upright_score(candidate_prepared.mask)
                )
                candidate_number += 1

        model = DSModel("mouse")
        ensemble = os.environ.get("BRAINBUILDER_DEEPSLICE_ENSEMBLE", "1") != "0"
        model.predict(
            image_directory=str(input_dir),
            ensemble=ensemble,
            section_numbers=True,
        )
        candidate_predictions = model.predictions.copy().reset_index(drop=True)
        candidate_quicknii_depths = np.asarray(
            calculate_brain_center_depths(candidate_predictions), dtype=np.float64
        )
        candidate_depths: dict[tuple[str, int], float] = {}
        row_positions: dict[tuple[str, int], int] = {}
        for position, ((_, row), depth) in enumerate(
            zip(
                candidate_predictions.iterrows(), candidate_quicknii_depths, strict=True
            )
        ):
            filename = Path(str(row["Filenames"])).name
            candidate = filename_to_candidate.get(filename)
            if candidate is None:
                raise WorkerBlocked(
                    f"DeepSlice returned an unknown orientation candidate: {filename}"
                )
            slice_record, rotation = candidate
            key = (str(slice_record.get("id")), rotation)
            if key in row_positions or not math.isfinite(float(depth)):
                raise WorkerBlocked(
                    f"DeepSlice returned an invalid duplicate orientation candidate for {key[0]}."
                )
            candidate_depths[key] = float(depth)
            row_positions[key] = position

        group_orientations = select_group_orientations(
            slices,
            candidate_depths,
            candidate_upright_scores,
        )
        selected_positions = [
            row_positions[
                (
                    str(slice_record.get("id")),
                    group_orientations[montage_group_key(slice_record)],
                )
            ]
            for slice_record in slices
        ]
        selected = (
            candidate_predictions.iloc[selected_positions].copy().reset_index(drop=True)
        )
        selected["nr"] = np.arange(1, len(selected) + 1, dtype=np.int64)
        model.predictions = selected
        if len(slices) > 1:
            model.enforce_index_order()
            model.propagate_angles()
            # Angle propagation rewrites every anchoring vector and can move
            # the calculated brain-center depths. Re-apply ordering so the
            # final QuickNII planes, not only their pre-propagation inputs,
            # remain serially monotonic.
            model.enforce_index_order()
            model.predictions = enforce_monotonic_brain_center_depths(
                model.predictions,
                calculate_brain_center_depths,
            )
        predictions = model.predictions.copy().reset_index(drop=True)

    predictions_path = out / "deepslice-predictions.csv"
    predictions.to_csv(predictions_path, index=False)
    candidate_path = out / "deepslice-orientation-candidates.csv"
    candidate_export = candidate_predictions.copy()
    candidate_export["sliceID"] = [
        str(filename_to_candidate[Path(str(value)).name][0].get("id"))
        for value in candidate_export["Filenames"]
    ]
    candidate_export["rotationDegrees"] = [
        filename_to_candidate[Path(str(value)).name][1]
        for value in candidate_export["Filenames"]
    ]
    candidate_export["quickNIIBrainCenterDepth"] = candidate_quicknii_depths
    candidate_export["dorsalUprightScore"] = [
        candidate_upright_scores[
            (
                str(filename_to_candidate[Path(str(value)).name][0].get("id")),
                filename_to_candidate[Path(str(value)).name][1],
            )
        ]
        for value in candidate_export["Filenames"]
    ]
    candidate_export["selected"] = [
        group_orientations[
            montage_group_key(filename_to_candidate[Path(str(value)).name][0])
        ]
        == filename_to_candidate[Path(str(value)).name][1]
        for value in candidate_export["Filenames"]
    ]
    candidate_export.to_csv(candidate_path, index=False)
    depths = np.asarray(calculate_brain_center_depths(predictions), dtype=np.float64)
    annotation = atlas.require_annotation()
    updated_ids: set[str] = set()
    for (_, row), depth in zip(predictions.iterrows(), depths, strict=True):
        filename = Path(str(row["Filenames"])).name
        candidate = filename_to_candidate.get(filename)
        if candidate is None:
            raise WorkerBlocked(
                f"DeepSlice returned an unknown input filename: {filename}"
            )
        slice_record, rotation = candidate
        if (slice_record.get("pose") or {}).get("manuallyLocked") is True:
            continue
        anchoring = np.asarray(
            [
                row[name]
                for name in ("ox", "oy", "oz", "ux", "uy", "uz", "vx", "vy", "vz")
            ],
            dtype=np.float64,
        )
        if not np.all(np.isfinite(anchoring)) or not math.isfinite(float(depth)):
            raise WorkerBlocked(
                f"DeepSlice returned non-finite coordinates for {slice_record.get('id')}."
            )
        # DeepSlice/QuickNII depth is the RAS y coordinate (posterior ->
        # anterior). BrainGlobe stores this atlas with an anterior ASR origin.
        atlas_depth = float((annotation.shape[0] - 1) - depth)
        atlas_index = int(np.clip(round(atlas_depth), 0, annotation.shape[0] - 1))
        prior_pose = slice_record.get("pose") or {}
        selected_orientation = {
            "rotationDegrees": rotation,
            "flipHorizontal": bool(prior_pose.get("flipHorizontal", False)),
            "flipVertical": bool(prior_pose.get("flipVertical", False)),
        }
        source = source_raster_path(slice_record, "structural")
        if source is None:
            raise WorkerBlocked(
                f"Structural source is missing for {slice_record.get('id')}."
            )
        prepared = load_prepared_image(source, selected_orientation, source_raster_path(slice_record, "selectionMask"))
        agreement = pose_silhouette_score(prepared, annotation[atlas_index] > 0)
        confidence = float(np.clip(0.30 + 0.65 * agreement, 0.0, 0.90))
        pose = {
            "atlasAPMicrons": float(atlas_depth * atlas.resolution[0]),
            "atlasSlicingAngles": slicing_angles_from_anchoring(anchoring),
            "rotationDegrees": float(rotation),
            "flipHorizontal": selected_orientation["flipHorizontal"],
            "flipVertical": selected_orientation["flipVertical"],
            "sourceConfidence": confidence,
            "manuallyLocked": False,
            "provenance": (
                f"DeepSlice {DEEPSLICE_VERSION} mouse ensemble={ensemble}; "
                f"montage {montage_group_key(slice_record)} selected {rotation} degrees; "
                "DeepSlice index ordering enforced; "
                "QuickNII RAS -> BrainGlobe ASR conversion; "
                f"annotation silhouette agreement={agreement:.3f}; worker {WORKER_VERSION}"
            ),
            "atlasAnchoring": anchoring.tolist(),
            "predictionImageSize": {
                "width": int(row["width"]),
                "height": int(row["height"]),
            },
        }
        install_pose(
            slice_record,
            pose,
            engine=f"DeepSlice {DEEPSLICE_VERSION} + QuickNII anchoring",
        )
        raw_ap = float(
            ((annotation.shape[0] - 1) - candidate_depths[(str(slice_record.get("id")), rotation)])
            * atlas.resolution[0]
        )
        final_ap = float(pose["atlasAPMicrons"])
        pose_qc = slice_record.setdefault("qc", {})
        pose_qc.update(
            rawPoseAPMicrons=raw_ap,
            orderedPoseAPMicrons=final_ap,
            poseAdjustmentMicrons=final_ap - raw_ap,
        )
        if abs(final_ap - raw_ap) > 10 * atlas.resolution[0]:
            pose_qc.setdefault("warnings", []).append(
                f"DeepSlice pose adjustment moved AP by {final_ap - raw_ap:+.1f} um "
                f"after serial-order/angle processing (raw {raw_ap:.1f}, final {final_ap:.1f} um). "
                "Review section order and anatomy; this disagreement does not establish which pose is correct."
            )
        if agreement < 0.48:
            warnings = slice_record.setdefault("qc", {}).setdefault("warnings", [])
            warnings.append(
                "DeepSlice plane has weak tissue/annotation silhouette agreement; verify before acceptance."
            )
        updated_ids.add(str(slice_record.get("id")))

    project.setdefault("provenance", {})["poseEngine"] = (
        f"DeepSlice {DEEPSLICE_VERSION}"
    )
    project["provenance"]["deepSlicePredictionsPath"] = str(predictions_path)
    project["provenance"]["deepSliceOrientationCandidatesPath"] = str(candidate_path)
    project["provenance"]["deepSliceGroupOrientations"] = group_orientations
    project["provenance"]["deepSliceIndexOrderEnforced"] = len(slices) > 1
    project["provenance"]["deepSliceIndexOrderRecheckedAfterAngles"] = len(slices) > 1
    project["provenance"]["deepSliceBrainCenterOrderCorrected"] = len(slices) > 1
    project["provenance"]["deepSliceUpdatedSliceIDs"] = sorted(updated_ids)
    return project


def estimate_poses_with_silhouettes(
    project: dict[str, Any], atlas: AtlasData
) -> dict[str, Any]:
    slices = project.get("slices", [])
    if not slices:
        raise WorkerBlocked("No sections are available for pose estimation.")

    histology: list[tuple[np.ndarray, float]] = []
    for slice_record in slices:
        artifacts = artifact_record(slice_record)
        mask_path = Path(artifacts["selectionMaskPath"]) if artifacts.get("selectionMaskPath") else None
        prepared = load_prepared_image(Path(artifacts["structuralImagePath"]), selection_mask_path=mask_path)
        histology.append(fit_mask_canvas(prepared.mask))

    candidate_indices: list[int] = []
    candidate_masks: list[np.ndarray] = []
    candidate_aspects: list[float] = []
    annotation = atlas.require_annotation()
    for index in range(0, atlas.reference.shape[0], 2):
        atlas_mask = annotation[index] > 0
        if float(atlas_mask.mean()) < 0.01:
            continue
        canvas, aspect = fit_mask_canvas(atlas_mask)
        candidate_indices.append(index)
        candidate_masks.append(canvas)
        candidate_aspects.append(aspect)
    if len(candidate_indices) < len(slices):
        raise WorkerBlocked(
            "Allen atlas did not provide enough non-empty coronal planes."
        )

    scores = np.zeros((len(slices), len(candidate_indices)), dtype=np.float64)
    for row, (hist_mask, hist_aspect) in enumerate(histology):
        for column, (atlas_mask, atlas_aspect) in enumerate(
            zip(candidate_masks, candidate_aspects, strict=True)
        ):
            overlap = dice_score(hist_mask, atlas_mask)
            aspect_score = math.exp(
                -abs(math.log(max(hist_aspect, 1e-6) / max(atlas_aspect, 1e-6)))
            )
            scores[row, column] = 0.78 * overlap + 0.22 * aspect_score

    forward_path, forward_score = monotonic_path(scores)
    reverse_path_reversed, reverse_score = monotonic_path(scores[::-1])
    if reverse_score > forward_score:
        selected_columns = reverse_path_reversed[::-1]
        direction = "posterior-to-anterior input order"
    else:
        selected_columns = forward_path
        direction = "anterior-to-posterior input order"

    for row, slice_record in enumerate(slices):
        if (slice_record.get("pose") or {}).get("manuallyLocked") is True:
            continue
        atlas_index = candidate_indices[int(selected_columns[row])]
        selected_score = float(scores[row, int(selected_columns[row])])
        alternatives = np.delete(scores[row], int(selected_columns[row]))
        ambiguity_margin = (
            selected_score - float(np.percentile(alternatives, 95))
            if alternatives.size
            else 0.0
        )
        confidence = float(
            np.clip(
                0.15 + 0.70 * selected_score + 2.0 * max(0.0, ambiguity_margin),
                0.0,
                0.82,
            )
        )
        pose = {
            "atlasAPMicrons": float(atlas_index * atlas.resolution[0]),
            "atlasSlicingAngles": {
                "pitchDegrees": 0.0,
                "rollDegrees": 0.0,
                "yawDegrees": 0.0,
            },
            "rotationDegrees": 0.0,
            "flipHorizontal": False,
            "flipVertical": False,
            "sourceConfidence": confidence,
            "manuallyLocked": False,
            "provenance": f"BrainGlobe {atlas.name} silhouette match; {direction}; worker {WORKER_VERSION}",
        }
        install_pose(
            slice_record,
            pose,
            engine="BrainGlobe annotation silhouette fallback",
        )
        if confidence < 0.45:
            warnings = slice_record.setdefault("qc", {}).setdefault("warnings", [])
            warnings.append(
                "Low-confidence automatic AP silhouette match; verify this plane before acceptance."
            )

    project.setdefault("provenance", {})["poseEngine"] = (
        "BrainGlobe annotation silhouette fallback"
    )
    return project


def estimate_poses(
    project: dict[str, Any], atlas: AtlasData, out: Path | None = None
) -> dict[str, Any]:
    for slice_record in project.get("slices", []):
        verify_selection_mask_identity(project, slice_record)
    use_deepslice = not (project.get("atlasAssets") or {}).get("fixturePath")
    use_deepslice = (
        use_deepslice and os.environ.get("BRAINBUILDER_DISABLE_DEEPSLICE", "0") != "1"
    )
    if use_deepslice:
        if out is None:
            raise WorkerBlocked(
                "DeepSlice pose estimation requires an output directory for provenance."
            )
        try:
            project = estimate_poses_with_deepslice(project, atlas, out)
        except Exception as error:
            project.setdefault("provenance", {})["deepSliceFallbackReason"] = (
                f"{type(error).__name__}: {error}"
            )
            project = estimate_poses_with_silhouettes(project, atlas)
            for slice_record in project.get("slices", []):
                warnings = slice_record.setdefault("qc", {}).setdefault("warnings", [])
                warnings.append(
                    f"DeepSlice was unavailable; used annotation-silhouette fallback: {error}"
                )
    else:
        project = estimate_poses_with_silhouettes(project, atlas)

    project["updatedAt"] = utc_now()
    project.setdefault("atlasAssets", {}).update(
        {
            "cachePath": str(atlas_cache_root(project)),
            "atlasRootPath": str(atlas.root_dir),
            "atlasName": atlas.name,
            "atlasVersion": atlas.version,
            "orientation": atlas.orientation,
            "resolutionMicrons": list(atlas.resolution),
        }
    )
    return project


def pose_transform(
    pose: dict[str, Any], *, engine: str = "BrainGlobe silhouette pose"
) -> dict[str, Any]:
    return {
        "id": "pose-prior",
        "kind": "pose",
        "stage": "pose",
        "direction": "atlasToSlice",
        "engine": f"{engine} {WORKER_VERSION}",
        "affine": {
            "m00": 1.0,
            "m01": 0.0,
            "m10": 0.0,
            "m11": 1.0,
            "tx": 0.0,
            "ty": 0.0,
        },
        "transformParametersPath": None,
        "landmarks": [],
        "metric": pose.get("sourceConfidence"),
        "createdAt": utc_now(),
        "provenance": pose.get("provenance", ""),
        "coordinateUnit": "micron",
        "rasterOrientation": raster_orientation(pose),
        "targetCoordinateSpace": "canonicalOrientedSliceMicrons",
    }


def atlas_plane(
    atlas: AtlasData,
    pose: dict[str, Any],
    moving_shape: tuple[int, int],
    moving_pixel_size: float,
) -> AtlasPlaneData:
    annotation_volume = atlas.require_annotation()
    ap_index = int(round(float(pose["atlasAPMicrons"]) / atlas.resolution[0]))
    if not 0 <= ap_index < atlas.reference.shape[0]:
        raise WorkerBlocked(
            f"AP index {ap_index} is outside atlas range 0..{atlas.reference.shape[0] - 1}."
        )

    anchoring_raw = pose.get("atlasAnchoring")
    if isinstance(anchoring_raw, list) and len(anchoring_raw) == 9:
        anchoring = np.asarray(anchoring_raw, dtype=np.float64)
        if not np.all(np.isfinite(anchoring)):
            raise WorkerBlocked("DeepSlice anchoring contains non-finite coordinates.")
        origin = anchoring[:3]
        u = anchoring[3:6]
        v = anchoring[6:9]
        height, width = moving_shape
        x_fraction = np.arange(width, dtype=np.float64) / max(1, width)
        y_fraction = np.arange(height, dtype=np.float64) / max(1, height)
        xx, yy = np.meshgrid(x_fraction, y_fraction)
        quicknii = origin[:, None, None] + u[:, None, None] * xx + v[:, None, None] * yy
        array_coordinates = quicknii_ras_to_brainglobe_asr(
            quicknii, atlas.reference.shape
        )
        raw = ndimage.map_coordinates(
            atlas.reference,
            array_coordinates,
            order=1,
            mode="constant",
            cval=0,
            prefilter=False,
        ).astype(np.float32)
        annotation_plane = ndimage.map_coordinates(
            annotation_volume,
            array_coordinates,
            order=0,
            mode="constant",
            cval=0,
            prefilter=False,
        ).astype(annotation_volume.dtype)
        # DeepSlice predicts QuickNII anchoring in the input image's pixel grid.
        # Use the histology spacing for residual 2D registration; U/V retain the
        # independent mapping from plane pixels back to 3D atlas coordinates.
        spacing = (float(moving_pixel_size), float(moving_pixel_size))
        atlas_origin = quicknii_ras_to_brainglobe_asr(origin, atlas.reference.shape)
        atlas_u = quicknii_ras_vector_to_brainglobe_asr(u)
        atlas_v = quicknii_ras_vector_to_brainglobe_asr(v)
        center_atlas = atlas_origin + 0.5 * atlas_u + 0.5 * atlas_v
        center_ap_index = int(
            np.clip(round(center_atlas[0]), 0, atlas.reference.shape[0] - 1)
        )
    else:
        raw = atlas.reference[ap_index].astype(np.float32)
        annotation_plane = annotation_volume[ap_index]
        height, width = raw.shape
        atlas_origin = np.asarray([float(ap_index), 0.0, 0.0], dtype=np.float64)
        atlas_u = np.asarray([0.0, 0.0, float(width)], dtype=np.float64)
        atlas_v = np.asarray([0.0, float(height), 0.0], dtype=np.float64)
        spacing = (float(atlas.resolution[2]), float(atlas.resolution[1]))
        center_ap_index = ap_index

    brain = annotation_plane > 0
    coverage = float(brain.mean())
    if coverage < 0.01:
        raise WorkerBlocked(
            f"Atlas annotation plane has implausible brain coverage {coverage:.3f}; verify the AP/angle estimate."
        )
    if not all(0.1 <= value <= 100.0 for value in spacing):
        raise WorkerBlocked(f"Atlas plane spacing is implausible: {spacing} um/px.")
    normalized = normalize_intensity(raw, brain)
    normalized = filters.gaussian(normalized, sigma=0.8, preserve_range=True).astype(
        np.float32
    )
    image = sitk.GetImageFromArray(normalized)
    image.SetSpacing(spacing)
    return AtlasPlaneData(
        gray=normalized,
        mask=brain,
        annotation=annotation_plane,
        image=image,
        center_ap_index=center_ap_index,
        atlas_origin=atlas_origin,
        atlas_u=atlas_u,
        atlas_v=atlas_v,
        width=width,
        height=height,
        spacing=spacing,
    )


def moving_sitk(
    image: np.ndarray, pixel_size: float, *, pixel_id: int = sitk.sitkFloat32
) -> sitk.Image:
    output = sitk.GetImageFromArray(np.asarray(image))
    output.SetSpacing((float(pixel_size), float(pixel_size)))
    return sitk.Cast(output, pixel_id)


def register_affine(
    fixed: sitk.Image,
    moving: sitk.Image,
    config: RegistrationConfig,
    *,
    fixed_mask: sitk.Image | None = None,
    moving_mask: sitk.Image | None = None,
) -> tuple[sitk.Transform, sitk.Image, dict[str, Any]]:
    registration = sitk.ImageRegistrationMethod()
    registration.SetMetricAsMattesMutualInformation(config.histogram_bins)
    registration.SetMetricSamplingStrategy(registration.RANDOM)
    registration.SetMetricSamplingPercentage(
        config.sampling_percentage, config.random_seed
    )
    registration.SetInterpolator(sitk.sitkLinear)
    if fixed_mask is not None:
        registration.SetMetricFixedMask(sitk.Cast(fixed_mask, sitk.sitkUInt8))
    if moving_mask is not None:
        registration.SetMetricMovingMask(sitk.Cast(moving_mask, sitk.sitkUInt8))
    registration.SetOptimizerAsRegularStepGradientDescent(
        learningRate=0.75,
        minStep=0.005,
        numberOfIterations=max(80, config.iterations),
        relaxationFactor=0.55,
        gradientMagnitudeTolerance=1e-6,
        estimateLearningRate=registration.EachIteration,
        maximumStepSizeInPhysicalUnits=25.0,
    )
    registration.SetOptimizerScalesFromPhysicalShift()
    registration.SetShrinkFactorsPerLevel(config.shrink_factors)
    registration.SetSmoothingSigmasPerLevel(config.smoothing_sigmas)
    registration.SmoothingSigmasAreSpecifiedInPhysicalUnitsOff()
    initial = sitk.CenteredTransformInitializer(
        fixed,
        moving,
        sitk.AffineTransform(2),
        sitk.CenteredTransformInitializerFilter.GEOMETRY,
    )
    registration.SetInitialTransform(initial, inPlace=False)
    result = registration.Execute(fixed, moving)
    warped = sitk.Resample(
        moving, fixed, result, sitk.sitkLinear, 0.0, sitk.sitkFloat32
    )
    return (
        result,
        warped,
        {
            "metric": float(registration.GetMetricValue()),
            "iteration": int(registration.GetOptimizerIteration()),
            "stop": registration.GetOptimizerStopConditionDescription(),
            "initialTransform": initial,
        },
    )


def affine_from_landmarks(
    landmarks: list[CorrectionLandmark],
    plane: AtlasPlaneData,
    moving_shape: tuple[int, int],
    pixel_size: float,
) -> tuple[sitk.AffineTransform, float]:
    """Fit atlas-plane microns -> canonical-slice microns, without MI refinement."""
    if len(landmarks) < 3:
        raise WorkerBlocked("Affine correction requires at least three paired landmarks.")
    if len({point.id for point in landmarks}) != len(landmarks):
        raise WorkerBlocked("Correction landmark IDs must be unique.")
    atlas_pixels = np.asarray([[p.atlasPoint.x, p.atlasPoint.y] for p in landmarks])
    slice_pixels = np.asarray([[p.slicePoint.x, p.slicePoint.y] for p in landmarks])
    if np.any(atlas_pixels > np.asarray([plane.width - 1, plane.height - 1])):
        raise WorkerBlocked("An atlas landmark lies outside the displayed atlas reference image.")
    if np.any(slice_pixels > np.asarray([moving_shape[1] - 1, moving_shape[0] - 1])):
        raise WorkerBlocked("A slice landmark lies outside the canonical structural image.")
    atlas_points = atlas_pixels * np.asarray(plane.spacing)
    slice_points = slice_pixels * pixel_size
    atlas_center, slice_center = atlas_points.mean(axis=0), slice_points.mean(axis=0)
    centered = atlas_points - atlas_center
    if (
        np.linalg.matrix_rank(centered) < 2
        or np.linalg.matrix_rank(slice_points - slice_center) < 2
    ):
        raise WorkerBlocked("Affine correction requires non-collinear landmarks in both images.")
    matrix = np.linalg.lstsq(centered, slice_points - slice_center, rcond=None)[0].T
    if not np.all(np.isfinite(matrix)) or abs(float(np.linalg.det(matrix))) < 1e-9:
        raise WorkerBlocked("Landmarks produce a singular affine correction.")
    if float(np.linalg.det(matrix)) < 0:
        raise WorkerBlocked(
            "Landmarks would mirror the section; correct landmark pairing or raster orientation first."
        )
    offset = slice_center - matrix @ atlas_center
    result = sitk.AffineTransform(2)
    result.SetMatrix(matrix.ravel().tolist())
    result.SetTranslation(offset.tolist())
    residuals = atlas_points @ matrix.T + offset - slice_points
    rms = float(np.sqrt(np.mean(np.sum(residuals ** 2, axis=1))))
    return result, rms


def affine_component(result: sitk.Transform) -> sitk.AffineTransform:
    current = result
    while current.GetName() == "CompositeTransform":
        composite = sitk.CompositeTransform(current)
        if composite.GetNumberOfTransforms() == 0:
            raise RuntimeError("SimpleITK returned an empty CompositeTransform.")
        current = composite.GetNthTransform(composite.GetNumberOfTransforms() - 1)
    try:
        return sitk.AffineTransform(current)
    except RuntimeError as error:
        raise RuntimeError(
            f"Expected a 2D affine transform, got {current.GetName()}."
        ) from error


def affine_json(result: sitk.Transform) -> dict[str, float]:
    affine = affine_component(result)
    matrix = np.asarray(affine.GetMatrix(), dtype=np.float64).reshape(2, 2)
    center = np.asarray(affine.GetCenter(), dtype=np.float64)
    translation = np.asarray(affine.GetTranslation(), dtype=np.float64)
    offset = center + translation - matrix @ center
    return {
        "m00": float(matrix[0, 0]),
        "m01": float(matrix[0, 1]),
        "m10": float(matrix[1, 0]),
        "m11": float(matrix[1, 1]),
        "tx": float(offset[0]),
        "ty": float(offset[1]),
    }


def resample_rgb(
    rgb: np.ndarray, pixel_size: float, fixed: sitk.Image, result: sitk.Transform
) -> np.ndarray:
    channels: list[np.ndarray] = []
    for channel_index in range(3):
        source = moving_sitk(rgb[..., channel_index].astype(np.float32), pixel_size)
        warped = sitk.Resample(
            source, fixed, result, sitk.sitkLinear, 0.0, sitk.sitkFloat32
        )
        channels.append(np.asarray(sitk.GetArrayFromImage(warped), dtype=np.float32))
    return np.clip(np.stack(channels, axis=-1), 0.0, 1.0)


def registration_iou(
    mask: np.ndarray,
    pixel_size: float,
    fixed: sitk.Image,
    atlas_mask: np.ndarray,
    result: sitk.Transform,
) -> float:
    moving_mask = moving_sitk(
        mask.astype(np.uint8), pixel_size, pixel_id=sitk.sitkUInt8
    )
    warped = sitk.Resample(
        moving_mask, fixed, result, sitk.sitkNearestNeighbor, 0, sitk.sitkUInt8
    )
    registered_mask = sitk.GetArrayFromImage(warped) > 0
    intersection = int(np.logical_and(registered_mask, atlas_mask).sum())
    union = int(np.logical_or(registered_mask, atlas_mask).sum())
    return 1.0 if union == 0 else float(intersection / union)


def channel_gray(
    path_value: str | None,
    fallback: PreparedImage,
    pose: dict[str, Any] | None = None,
    selection_mask_path: Path | None = None,
) -> np.ndarray:
    if not path_value:
        return fallback.gray
    path = Path(path_value)
    if not path.is_file():
        return fallback.gray
    loaded = load_prepared_image(path, pose, selection_mask_path)
    return loaded.gray


def no_track_detection(reason: str, *, status: str = "noTrack") -> dict[str, Any]:
    return {
        "status": status,
        "channelName": "unavailable",
        "points": [],
        "atlasPoints": [],
        "lineStart": None,
        "lineEnd": None,
        "confidence": 0.0,
        "rmseMicrons": None,
        "reviewAccepted": False,
        "provenance": reason,
    }


def save_probe_track_review_overlay(
    path: Path,
    structural: np.ndarray,
    probe: np.ndarray,
    points: np.ndarray,
    inliers: np.ndarray,
    start: np.ndarray,
    end: np.ndarray,
) -> None:
    """Write a review image in native slice pixels with the probe channel visible."""
    structural_display = np.clip(structural, 0.0, 1.0)
    probe_display = np.clip(probe, 0.0, 1.0)
    rgb = np.stack(
        [
            structural_display * 0.42,
            np.maximum(structural_display * 0.28, probe_display),
            structural_display * 0.34,
        ],
        axis=-1,
    )
    image = Image.fromarray((np.clip(rgb, 0.0, 1.0) * 255).astype(np.uint8), mode="RGB")
    drawer = ImageDraw.Draw(image)
    for point, is_inlier in zip(points, inliers, strict=True):
        if not is_inlier:
            continue
        x, y = float(point[0]), float(point[1])
        drawer.ellipse((x - 1.8, y - 1.8, x + 1.8, y + 1.8), fill=(60, 235, 255))
    drawer.line(
        [(float(start[0]), float(start[1])), (float(end[0]), float(end[1]))],
        fill=(255, 218, 64),
        width=3,
    )
    for endpoint in (start, end):
        x, y = float(endpoint[0]), float(endpoint[1])
        drawer.ellipse(
            (x - 4, y - 4, x + 4, y + 4), fill=(255, 218, 64), outline=(8, 12, 18)
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


def detect_probe_track(
    slice_record: dict[str, Any],
    prepared: PreparedImage,
    slice_dir: Path,
) -> dict[str, Any]:
    artifacts = artifact_record(slice_record)
    artifacts["trackMaskPath"] = None
    artifacts["trackOverlayPath"] = None
    probe_path = source_raster_path(slice_record, "probe")
    if probe_path is None or not probe_path.is_file():
        return no_track_detection(
            "No probe-label channel was materialized; the structural channel was intentionally not used as a fallback."
        )
    pose = slice_record.get("pose") or {}
    probe = channel_gray(str(probe_path), prepared, pose, source_raster_path(slice_record, "selectionMask"))
    structural = prepared.gray
    if probe.shape != structural.shape or prepared.mask.shape != structural.shape:
        raise WorkerBlocked(
            f"Probe/structural channel dimensions differ for {slice_record.get('id')}: "
            f"probe={probe.shape}, structural={structural.shape}, mask={prepared.mask.shape}."
        )
    mask = prepared.mask
    eroded = morphology.erosion(
        mask, footprint=morphology.disk(max(2, min(mask.shape) // 80))
    )
    sample_coordinates = np.argwhere(eroded)
    if sample_coordinates.shape[0] < 100:
        return no_track_detection("Insufficient tissue area for track detection.")

    rng = np.random.default_rng(RANDOM_SEED)
    if sample_coordinates.shape[0] > 40_000:
        sample_coordinates = sample_coordinates[
            rng.choice(sample_coordinates.shape[0], 40_000, replace=False)
        ]
    y = sample_coordinates[:, 0]
    x = sample_coordinates[:, 1]
    predictor = structural[y, x].reshape(-1, 1)
    response = probe[y, x]
    robust = HuberRegressor(epsilon=1.35, max_iter=100)
    robust.fit(predictor, response)
    predicted = robust.predict(structural.reshape(-1, 1)).reshape(structural.shape)
    residual = np.maximum(0.0, probe - predicted)
    radius = max(3, min(residual.shape) // 45)
    enhanced = morphology.white_tophat(residual, footprint=morphology.disk(radius))
    values = enhanced[eroded]
    median = float(np.median(values))
    mad = float(np.median(np.abs(values - median))) * 1.4826
    threshold = max(float(np.percentile(values, 99.5)), median + 6.0 * max(mad, 1e-6))
    low_threshold = max(
        float(np.percentile(values, 98.0)), median + 3.0 * max(mad, 1e-6)
    )
    binary = (
        filters.apply_hysteresis_threshold(enhanced, low_threshold, threshold) & eroded
    )
    minimum_area = max(12, binary.size // 100_000)
    binary = morphology.remove_small_objects(
        binary, max_size=minimum_area - 1, connectivity=2
    )
    labels = measure.label(binary, connectivity=2)
    regions = [
        region
        for region in measure.regionprops(labels, intensity_image=enhanced)
        if region.area >= 12 and region.area <= max(5_000, binary.size // 5)
    ]
    strongest_mean = max(
        (float(region.intensity_mean) for region in regions), default=0.0
    )
    # Every hysteresis component already contains a seed at or above ``threshold``.
    # Comparing its *mean* intensity with 1.15 × that seed threshold is therefore
    # self-defeating for a real, tapered track: the lower-threshold support pixels
    # pull the component mean below the seed value.  Keep components relative to
    # the strongest supported component instead; the hysteresis thresholds remain
    # the absolute noise guard.
    signal_floor = max(low_threshold, strongest_mean * 0.45)
    regions = [
        region for region in regions if float(region.intensity_mean) >= signal_floor
    ]
    valid_labels = [region.label for region in regions]
    candidate_mask = (
        np.isin(labels, valid_labels) if valid_labels else np.zeros_like(binary)
    )
    skeleton = morphology.skeletonize(candidate_mask)
    skeleton_yx = np.argwhere(skeleton)
    if skeleton_yx.shape[0] > 600:
        rng = np.random.default_rng(RANDOM_SEED)
        keep = np.sort(rng.choice(skeleton_yx.shape[0], 600, replace=False))
        skeleton_yx = skeleton_yx[keep]
    points = np.asarray(skeleton_yx[:, ::-1], dtype=np.float64)
    detection_mask_path = slice_dir / "probe-track-mask.png"
    save_mask(detection_mask_path, candidate_mask)
    artifacts["trackMaskPath"] = str(detection_mask_path)

    if points.shape[0] < 3:
        return {
            "status": "noTrack" if points.shape[0] == 0 else "review",
            "channelName": "probe channel",
            "points": [{"x": float(p[0]), "y": float(p[1])} for p in points],
            "atlasPoints": [],
            "lineStart": None,
            "lineEnd": None,
            "confidence": min(0.25, points.shape[0] / 8.0),
            "rmseMicrons": None,
            "provenance": f"scikit-image skeleton after Huber crosstalk removal; threshold={threshold:.5f}; fewer than 3 skeleton points",
        }

    model, inliers = measure.ransac(
        points,
        measure.LineModelND,
        min_samples=2,
        residual_threshold=max(2.0, min(points.shape) * 0.012),
        max_trials=500,
        rng=RANDOM_SEED,
    )
    if model is None or inliers is None or int(inliers.sum()) < 3:
        return {
            "status": "review",
            "channelName": "probe channel",
            "points": [{"x": float(p[0]), "y": float(p[1])} for p in points],
            "atlasPoints": [],
            "lineStart": None,
            "lineEnd": None,
            "confidence": 0.25,
            "rmseMicrons": None,
            "provenance": "Probe-like components were found, but a robust line was not supported by 3 inliers.",
        }

    origin = np.asarray(model.origin, dtype=np.float64)
    direction = np.asarray(model.direction, dtype=np.float64)
    inlier_indices = np.flatnonzero(inliers)
    inlier_points = points[inlier_indices]
    projections = (inlier_points - origin) @ direction
    order = np.argsort(projections)
    ordered_indices = inlier_indices[order]
    ordered_projections = projections[order]
    maximum_gap = max(10.0, min(mask.shape) * 0.08)
    split_at = np.flatnonzero(np.diff(ordered_projections) > maximum_gap) + 1
    contiguous_groups = np.split(np.arange(len(ordered_indices)), split_at)
    best_group = max(
        contiguous_groups,
        key=lambda group: (
            len(group),
            float(ordered_projections[group[-1]] - ordered_projections[group[0]]),
        ),
    )
    selected_indices = ordered_indices[best_group]
    selected_points = points[selected_indices]
    if selected_points.shape[0] < 3:
        return {
            "status": "review",
            "channelName": "probe channel",
            "points": [
                {"x": float(p[0]), "y": float(p[1]), "inlier": False} for p in points
            ],
            "atlasPoints": [],
            "lineStart": None,
            "lineEnd": None,
            "confidence": 0.2,
            "rmseMicrons": None,
            "provenance": "Line-like fluorescence was split by a large unsupported gap; no contiguous segment had 3 points.",
        }
    origin = selected_points.mean(axis=0)
    _, _, right_vectors = np.linalg.svd(selected_points - origin, full_matrices=False)
    direction = np.asarray(right_vectors[0], dtype=np.float64)
    selected_projections = (selected_points - origin) @ direction
    start = origin + direction * float(selected_projections.min())
    end = origin + direction * float(selected_projections.max())
    segment_span = float(selected_projections.max() - selected_projections.min())
    minimum_span = max(8.0, min(mask.shape) * 0.04)
    if segment_span < minimum_span:
        return {
            "status": "review",
            "channelName": "probe channel",
            "points": [
                {"x": float(p[0]), "y": float(p[1]), "inlier": False} for p in points
            ],
            "atlasPoints": [],
            "lineStart": None,
            "lineEnd": None,
            "confidence": 0.2,
            "rmseMicrons": None,
            "provenance": f"Candidate fluorescent segment was too short ({segment_span:.1f}px < {minimum_span:.1f}px).",
        }
    final_inliers = np.zeros(points.shape[0], dtype=bool)
    final_inliers[selected_indices] = True
    centered = selected_points - origin
    residual_vectors = centered - np.outer(centered @ direction, direction)
    residuals = np.linalg.norm(residual_vectors, axis=1)
    pixel_size = float(slice_record.get("pixelSizeMicrons") or 1.0)
    rmse = float(np.sqrt(np.mean(np.square(residuals))) * pixel_size)
    inlier_fraction = float(final_inliers.mean())
    sorted_selected = np.sort(selected_projections)
    largest_supported_gap = (
        float(np.diff(sorted_selected).max())
        if len(sorted_selected) > 1
        else segment_span
    )
    continuity = float(
        np.clip(1.0 - largest_supported_gap / max(segment_span, 1.0), 0.0, 1.0)
    )
    support_score = min(1.0, selected_points.shape[0] / 24.0)
    length_score = min(1.0, segment_span / max(1.0, min(mask.shape) * 0.30))
    confidence = float(
        np.clip(
            0.10
            + 0.30 * support_score
            + 0.20 * length_score
            + 0.20 * inlier_fraction
            + 0.20 * continuity,
            0.0,
            0.95,
        )
    )
    neighborhood = max(3, int(round(mask.shape[1] * 0.025)))

    def dorsal_surface_distance_fraction(endpoint: np.ndarray) -> float:
        x_index = int(np.clip(round(float(endpoint[0])), 0, mask.shape[1] - 1))
        left = max(0, x_index - neighborhood)
        right = min(mask.shape[1], x_index + neighborhood + 1)
        tissue_y = np.flatnonzero(mask[:, left:right].any(axis=1))
        if tissue_y.size == 0:
            return 1.0
        return float(
            max(0.0, float(endpoint[1]) - float(tissue_y.min())) / max(1, mask.shape[0])
        )

    dorsal_entry_distance = min(
        dorsal_surface_distance_fraction(start),
        dorsal_surface_distance_fraction(end),
    )
    detection = {
        "status": "review",
        "channelName": "probe channel",
        "points": [
            {
                "x": float(point[0]),
                "y": float(point[1]),
                "inlier": bool(is_inlier),
            }
            for point, is_inlier in zip(points, final_inliers, strict=True)
        ],
        "atlasPoints": [],
        "lineStart": {"x": float(start[0]), "y": float(start[1])},
        "lineEnd": {"x": float(end[0]), "y": float(end[1])},
        "confidence": confidence,
        "rmseMicrons": rmse,
        "reviewAccepted": False,
        "dorsalEntryDistanceFraction": dorsal_entry_distance,
        "provenance": (
            f"HuberRegressor crosstalk removal + scikit-image white_tophat/skeleton/LineModelND RANSAC; "
            f"{int(final_inliers.sum())}/{len(final_inliers)} contiguous inliers; span={segment_span:.1f}px; "
            f"largest_gap={largest_supported_gap:.1f}px; threshold={threshold:.5f}; "
            f"low_threshold={low_threshold:.5f}; component_mean_floor={signal_floor:.5f}; "
            f"dorsal_entry_distance={dorsal_entry_distance:.3f}; seed={RANDOM_SEED}"
        ),
    }
    track_review_path = slice_dir / "probe-track-overlay.png"
    save_probe_track_review_overlay(
        track_review_path,
        structural,
        probe,
        points,
        final_inliers,
        start,
        end,
    )
    artifacts["trackOverlayPath"] = str(track_review_path)
    return detection


def _canonical_undirected_endpoints(
    start: np.ndarray, end: np.ndarray
) -> tuple[np.ndarray, np.ndarray]:
    """Return stable A/B endpoints without assigning insertion direction."""
    start_key = tuple(float(value) for value in start)
    end_key = tuple(float(value) for value in end)
    return (start, end) if start_key <= end_key else (end, start)


def _track_point_id(slice_id: str, index: int, point: np.ndarray) -> str:
    digest = canonical_json_sha256(
        {
            "sliceID": slice_id,
            "sourceIndex": index,
            "x": round(float(point[0]), 9),
            "y": round(float(point[1]), 9),
        }
    )
    return f"{safe_name(slice_id)}-point-{digest[:16]}"


def _make_2d_track_candidate(
    *,
    slice_id: str,
    ordinal: int,
    all_points: np.ndarray,
    selected_indices: np.ndarray,
    pixel_size: float,
    mask_shape: tuple[int, int],
    provenance: str,
) -> dict[str, Any] | None:
    if selected_indices.size < 3:
        return None
    selected = all_points[selected_indices]
    origin = selected.mean(axis=0)
    _, _, right_vectors = np.linalg.svd(selected - origin, full_matrices=False)
    direction = np.asarray(right_vectors[0], dtype=np.float64)
    projections = (selected - origin) @ direction
    span = float(projections.max() - projections.min())
    minimum_span = max(8.0, min(mask_shape) * 0.04)
    if not math.isfinite(span) or span < minimum_span:
        return None
    start = origin + direction * float(projections.min())
    end = origin + direction * float(projections.max())
    start, end = _canonical_undirected_endpoints(start, end)
    centered = selected - origin
    residual_vectors = centered - np.outer(centered @ direction, direction)
    residuals = np.linalg.norm(residual_vectors, axis=1)
    rmse = float(np.sqrt(np.mean(np.square(residuals))) * pixel_size)
    point_records = []
    point_ids = []
    for source_index in selected_indices.tolist():
        point = all_points[source_index]
        point_id = _track_point_id(slice_id, int(source_index), point)
        point_ids.append(point_id)
        point_records.append(
            {
                "pointId": point_id,
                "x": float(point[0]),
                "y": float(point[1]),
                "inlier": True,
            }
        )
    candidate_digest = canonical_json_sha256(
        {
            "sliceID": slice_id,
            "pointIDs": sorted(point_ids),
            "endpointA": [round(float(value), 9) for value in start],
            "endpointB": [round(float(value), 9) for value in end],
        }
    )
    support_score = min(1.0, selected.shape[0] / 24.0)
    length_score = min(1.0, span / max(1.0, min(mask_shape) * 0.30))
    confidence = float(
        np.clip(0.15 + 0.45 * support_score + 0.35 * length_score, 0.0, 0.95)
    )
    return {
        "candidateId": f"{safe_name(slice_id)}-candidate-{ordinal:02d}-{candidate_digest[:12]}",
        "candidateDigest": candidate_digest,
        "status": "review",
        "channelName": "probe channel",
        "points": point_records,
        "atlasPoints": [],
        "lineStart": {"x": float(start[0]), "y": float(start[1])},
        "lineEnd": {"x": float(end[0]), "y": float(end[1])},
        "confidence": confidence,
        "rmseMicrons": rmse,
        "reviewAccepted": False,
        "autoQualified": False,
        "provenance": provenance,
        "blind": True,
    }


def save_probe_tracks_review_overlay(
    path: Path,
    structural: np.ndarray,
    probe: np.ndarray,
    candidates: list[dict[str, Any]],
) -> None:
    structural_display = np.clip(structural, 0.0, 1.0)
    probe_display = np.clip(probe, 0.0, 1.0)
    rgb = np.stack(
        [
            structural_display * 0.42,
            np.maximum(structural_display * 0.28, probe_display),
            structural_display * 0.34,
        ],
        axis=-1,
    )
    image_value = (np.clip(rgb, 0.0, 1.0) * 255).astype(np.uint8)
    image = Image.fromarray(image_value, mode="RGB")
    drawer = ImageDraw.Draw(image)
    palette = (
        (255, 218, 64),
        (65, 220, 255),
        (255, 120, 205),
        (125, 245, 125),
        (255, 155, 65),
    )
    for index, candidate in enumerate(candidates):
        color_value = palette[index % len(palette)]
        for point in candidate.get("points", []):
            x, y = float(point["x"]), float(point["y"])
            drawer.ellipse((x - 1.8, y - 1.8, x + 1.8, y + 1.8), fill=color_value)
        start = candidate.get("lineStart") or {}
        end = candidate.get("lineEnd") or {}
        if {"x", "y"}.issubset(start) and {"x", "y"}.issubset(end):
            drawer.line(
                [
                    (float(start["x"]), float(start["y"])),
                    (float(end["x"]), float(end["y"])),
                ],
                fill=color_value,
                width=3,
            )
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)


def detect_probe_tracks(
    slice_record: dict[str, Any],
    prepared: PreparedImage,
    slice_dir: Path,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Extract deterministic, mutually exclusive blind 2-D track candidates.

    The existing detector remains the preprocessing authority.  Its complete
    skeleton point set seeds an iterative RANSAC pass; no plan, ROI, expected
    count, or planned geometry is accepted by this function.
    """
    legacy = detect_probe_track(slice_record, prepared, slice_dir)
    raw_points = legacy.get("points", [])
    if not raw_points:
        return [], legacy
    points = np.asarray(
        [[float(point["x"]), float(point["y"])] for point in raw_points],
        dtype=np.float64,
    )
    if points.shape[0] < 3:
        return [], legacy
    slice_id = str(slice_record.get("id", "slice"))
    pixel_size = float(slice_record.get("pixelSizeMicrons") or 1.0)
    remaining = np.ones(points.shape[0], dtype=bool)
    initial = np.asarray(
        [bool(point.get("inlier", False)) for point in raw_points],
        dtype=bool,
    )
    candidates: list[dict[str, Any]] = []
    if int(initial.sum()) >= 3:
        first = _make_2d_track_candidate(
            slice_id=slice_id,
            ordinal=1,
            all_points=points,
            selected_indices=np.flatnonzero(initial),
            pixel_size=pixel_size,
            mask_shape=prepared.mask.shape,
            provenance=str(legacy.get("provenance", "blind 2-D RANSAC")),
        )
        remaining[initial] = False
        if first is not None:
            first["confidence"] = float(legacy.get("confidence", first["confidence"]))
            first["rmseMicrons"] = legacy.get("rmseMicrons", first["rmseMicrons"])
            candidates.append(first)

    residual_threshold = max(2.0, min(prepared.mask.shape) * 0.012)
    while int(remaining.sum()) >= 3 and len(candidates) < MAX_SLICE_TRACK_CANDIDATES:
        remaining_indices = np.flatnonzero(remaining)
        remaining_points = points[remaining_indices]
        model, local_inliers = measure.ransac(
            remaining_points,
            measure.LineModelND,
            min_samples=2,
            residual_threshold=residual_threshold,
            max_trials=500,
            rng=RANDOM_SEED + len(candidates) + 1,
        )
        if model is None or local_inliers is None or int(local_inliers.sum()) < 3:
            break
        model_indices = remaining_indices[np.flatnonzero(local_inliers)]
        model_points = points[model_indices]
        origin = np.asarray(model.origin, dtype=np.float64)
        direction = np.asarray(model.direction, dtype=np.float64)
        projections = (model_points - origin) @ direction
        order = np.argsort(projections)
        ordered_indices = model_indices[order]
        ordered_projections = projections[order]
        maximum_gap = max(10.0, min(prepared.mask.shape) * 0.08)
        split_at = np.flatnonzero(np.diff(ordered_projections) > maximum_gap) + 1
        groups = np.split(np.arange(len(ordered_indices)), split_at)
        best = max(
            groups,
            key=lambda group: (
                len(group),
                float(ordered_projections[group[-1]] - ordered_projections[group[0]]),
            ),
        )
        selected_indices = ordered_indices[best]
        candidate = _make_2d_track_candidate(
            slice_id=slice_id,
            ordinal=len(candidates) + 1,
            all_points=points,
            selected_indices=selected_indices,
            pixel_size=pixel_size,
            mask_shape=prepared.mask.shape,
            provenance=(
                "Blind iterative scikit-image LineModelND RANSAC over residual skeleton points; "
                f"residual_threshold={residual_threshold:.4f}; seed={RANDOM_SEED + len(candidates) + 1}"
            ),
        )
        # Remove all inliers of the attempted model so rejected short fragments
        # cannot cause a non-terminating rediscovery loop.
        remaining[model_indices] = False
        if candidate is not None:
            candidates.append(candidate)

    if len(candidates) >= MAX_SLICE_TRACK_CANDIDATES and int(remaining.sum()) >= 3:
        raise WorkerBlocked(
            f"Slice {slice_id} exceeded the {MAX_SLICE_TRACK_CANDIDATES}-candidate blind track limit."
        )
    if candidates:
        probe_path = source_raster_path(slice_record, "probe")
        if probe_path is not None and probe_path.is_file():
            probe = channel_gray(
                str(probe_path), prepared, slice_record.get("pose") or {},
                source_raster_path(slice_record, "selectionMask")
            )
            overlay_path = slice_dir / "probe-tracks-overlay.png"
            save_probe_tracks_review_overlay(
                overlay_path,
                prepared.gray,
                probe,
                candidates,
            )
            artifact_record(slice_record)["trackOverlayPath"] = str(overlay_path)
    return candidates, legacy


def map_track_to_atlas(
    detection: dict[str, Any],
    result: sitk.Transform,
    pixel_size: float,
    plane: AtlasPlaneData,
    atlas: AtlasData,
) -> None:
    inverse = result.GetInverse()
    mapped: list[dict[str, Any]] = []
    for point in detection.get("points", []):
        if point.get("inlier") is False:
            continue
        slice_physical = (
            float(point["x"]) * pixel_size,
            float(point["y"]) * pixel_size,
        )
        plane_physical = inverse.TransformPoint(slice_physical)
        atlas_physical = plane.atlas_coordinate_for_physical_point(
            plane_physical, atlas
        )
        mapped.append(
            {
                "slicePoint": {"x": float(point["x"]), "y": float(point["y"])},
                "apMicrons": float(atlas_physical[0]),
                "dorsalVentralMicrons": float(atlas_physical[1]),
                "rightLeftMicrons": float(atlas_physical[2]),
                # A 2D line-fit residual does not quantify atlas registration uncertainty.
                "uncertaintyMicrons": None,
                "atlasPlanePoint": {
                    "x": float(plane_physical[0] / plane.spacing[0]),
                    "y": float(plane_physical[1] / plane.spacing[1]),
                },
            }
        )
    detection["atlasPoints"] = mapped
    if mapped:
        has_dorsal_entry = (
            float(detection.get("dorsalEntryDistanceFraction", 1.0)) <= 0.15
        )
        detection["status"] = "atlasMappedReview"
        detection["autoQualified"] = bool(
            float(detection.get("confidence", 0.0)) >= 0.80 and has_dorsal_entry
        )


def structure_info(atlas: AtlasData, structure_id: int) -> dict[str, Any]:
    if structure_id == 0:
        return {
            "id": 0,
            "acronym": "outside",
            "name": "Outside atlas",
            "rgb": [0, 0, 0],
        }
    try:
        entry = atlas.structures[structure_id]
    except (KeyError, TypeError):
        return {
            "id": structure_id,
            "acronym": str(structure_id),
            "name": "Unknown",
            "rgb": [170, 170, 170],
        }
    rgb = entry.get("rgb_triplet") or entry.get("rgb") or [170, 170, 170]
    return {
        "id": structure_id,
        "acronym": str(entry.get("acronym", structure_id)),
        "name": str(entry.get("name", "Unknown")),
        "rgb": [int(value) for value in rgb],
    }


def colorize_annotation(annotation: np.ndarray, atlas: AtlasData) -> np.ndarray:
    output = np.zeros((*annotation.shape, 3), dtype=np.uint8)
    for structure_id in np.unique(annotation):
        info = structure_info(atlas, int(structure_id))
        output[annotation == structure_id] = np.asarray(info["rgb"], dtype=np.uint8)
    return output


def write_registration_artifacts(
    slice_record: dict[str, Any],
    slice_dir: Path,
    atlas: AtlasData,
    ap_index: int,
    atlas_gray: np.ndarray,
    registered_rgb: np.ndarray,
    annotation_plane: np.ndarray,
    detection: dict[str, Any],
) -> None:
    slice_dir.mkdir(parents=True, exist_ok=True)
    artifacts = artifact_record(slice_record)
    atlas_u8 = (np.clip(atlas_gray, 0, 1) * 255).astype(np.uint8)
    registered_u8 = (np.clip(registered_rgb, 0, 1) * 255).astype(np.uint8)
    boundary = segmentation.find_boundaries(annotation_plane, mode="outer")
    labels_rgb = colorize_annotation(annotation_plane, atlas)
    overlay = (
        registered_u8.astype(np.float32) * 0.88 + labels_rgb.astype(np.float32) * 0.12
    ).astype(np.uint8)
    overlay[boundary] = np.asarray([0, 255, 255], dtype=np.uint8)
    boundary_rgb = registered_u8.copy()
    boundary_rgb[boundary] = np.asarray([0, 255, 255], dtype=np.uint8)

    registered_gray = color.rgb2gray(registered_rgb)
    difference = np.abs(
        normalize_intensity(registered_gray) - normalize_intensity(atlas_gray)
    )
    difference_rgb = np.stack(
        [
            np.clip(difference * 2.0, 0, 1),
            np.clip(1.0 - difference, 0, 1) * 0.25,
            np.zeros_like(difference),
        ],
        axis=-1,
    )
    difference_u8 = (difference_rgb * 255).astype(np.uint8)

    atlas_rgb = np.repeat(atlas_u8[..., None], 3, axis=-1)
    checker = registered_u8.copy()
    cell = 24
    yy, xx = np.indices(atlas_gray.shape)
    use_atlas = ((yy // cell) + (xx // cell)) % 2 == 0
    checker[use_atlas] = atlas_rgb[use_atlas]

    atlas_path = slice_dir / "atlas-reference.png"
    registered_path = slice_dir / "registered-section.png"
    overlay_path = slice_dir / "atlas-overlay.png"
    boundary_path = slice_dir / "atlas-boundaries.png"
    checker_path = slice_dir / "checkerboard.png"
    difference_path = slice_dir / "difference.png"
    annotation_path = slice_dir / "annotation-ids.tif"
    Image.fromarray(atlas_u8, mode="L").save(atlas_path)
    Image.fromarray(registered_u8, mode="RGB").save(registered_path)
    Image.fromarray(overlay, mode="RGB").save(overlay_path)
    Image.fromarray(boundary_rgb, mode="RGB").save(boundary_path)
    Image.fromarray(checker, mode="RGB").save(checker_path)
    Image.fromarray(difference_u8, mode="RGB").save(difference_path)
    tifffile.imwrite(
        annotation_path, annotation_plane.astype(np.uint32), photometric="minisblack"
    )

    existing_track_overlay = artifacts.get("trackOverlayPath")
    if existing_track_overlay and Path(existing_track_overlay).is_file():
        track_overlay_path = Path(existing_track_overlay)
    else:
        track_overlay_path = slice_dir / "atlas-track-overlay.png"
        track_image = Image.fromarray(overlay, mode="RGB")
        drawer = ImageDraw.Draw(track_image)
        atlas_points = detection.get("atlasPoints", [])
        display_points: list[tuple[float, float]] = []
        for point in atlas_points:
            plane_point = point.get("atlasPlanePoint") or {}
            x = float(plane_point.get("x", 0.0))
            y = float(plane_point.get("y", 0.0))
            display_points.append((x, y))
            drawer.ellipse(
                (x - 4, y - 4, x + 4, y + 4), fill=(255, 230, 0), outline=(0, 0, 0)
            )
        if len(display_points) >= 2:
            drawer.line(display_points, fill=(255, 230, 0), width=3)
        track_image.save(track_overlay_path)

    artifacts.update(
        {
            "atlasReferencePath": str(atlas_path),
            "registeredImagePath": str(registered_path),
            "overlayImagePath": str(overlay_path),
            "boundaryImagePath": str(boundary_path),
            "checkerboardImagePath": str(checker_path),
            "differenceImagePath": str(difference_path),
            "annotationImagePath": str(annotation_path),
            "trackOverlayPath": str(track_overlay_path),
            "atlasAPIndex": int(ap_index),
        }
    )


def non_degrading_affine_result(
    initial: sitk.Transform,
    optimized: sitk.Transform,
    initial_iou: float,
    optimized_iou: float,
    *,
    tolerance: float = 0.01,
) -> tuple[sitk.Transform, float, bool]:
    """Reject an optimizer result that materially worsens tissue support.

    Mattes mutual information can occasionally walk away from an already good
    pose initialization. The review gate used to flag that result but still
    serialized and displayed it. Keeping the centered initializer makes the
    generated overlay and 3D estimate no worse while preserving the warning.
    """
    rejected = optimized_iou + tolerance < initial_iou
    if rejected:
        return initial, float(initial_iou), True
    return optimized, float(optimized_iou), False


def register_one_slice(
    project: dict[str, Any],
    slice_record: dict[str, Any],
    stage: str,
    out: Path,
    atlas: AtlasData,
    config: RegistrationConfig,
    *,
    landmarks: list[CorrectionLandmark] | None = None,
) -> dict[str, Any]:
    verify_selection_mask_identity(project, slice_record)
    if stage == "spline":
        raise WorkerBlocked(
            "This worker supports affine registration. For nonlinear refinement, use "
            "Export to ABBA and the official ABBA affine/spline workflow."
        )
    pose = slice_record.get("pose")
    if not pose:
        raise WorkerBlocked(
            f"{slice_record.get('id')} has no AP pose. Run estimate-pose first."
        )
    pixel_size = float(slice_record.get("pixelSizeMicrons") or 0)
    if not 0.1 <= pixel_size <= 100.0:
        raise WorkerBlocked(
            f"{slice_record.get('id')} has implausible pixel size {pixel_size:g} um/px; expected 0.1..100."
        )

    artifacts = artifact_record(slice_record)
    structural_path = source_raster_path(slice_record, "structural")
    if structural_path is None:
        raise WorkerBlocked(
            f"{slice_record.get('id')} has no structural source raster."
        )
    prepared = load_prepared_image(structural_path, pose, source_raster_path(slice_record, "selectionMask"))
    slice_dir = out / "slices" / safe_name(str(slice_record.get("id", "slice")))
    materialize_oriented_source_artifacts(slice_record, prepared, slice_dir)
    plane = atlas_plane(atlas, pose, prepared.gray.shape, pixel_size)
    fixed = plane.image
    moving = moving_sitk(prepared.gray, pixel_size)
    fixed_mask_image = sitk.GetImageFromArray(plane.mask.astype(np.uint8))
    fixed_mask_image.SetSpacing(plane.spacing)
    moving_mask_image = moving_sitk(
        prepared.mask.astype(np.uint8), pixel_size, pixel_id=sitk.sitkUInt8
    )
    landmark_rms = None
    if landmarks:
        optimized_result, landmark_rms = affine_from_landmarks(
            landmarks, plane, prepared.gray.shape, pixel_size
        )
        metrics = {
            "metric": None,
            "stop": "Manual paired-landmark least squares; no automatic intensity refinement",
            "initialTransform": sitk.AffineTransform(2),
        }
    else:
        optimized_result, _, metrics = register_affine(
            fixed,
            moving,
            config,
            fixed_mask=fixed_mask_image,
            moving_mask=moving_mask_image,
        )
    initial_iou = registration_iou(
        prepared.mask,
        pixel_size,
        fixed,
        plane.mask,
        metrics["initialTransform"],
    )
    optimized_iou = registration_iou(
        prepared.mask,
        pixel_size,
        fixed,
        plane.mask,
        optimized_result,
    )
    if landmarks:
        result, qc_iou, optimizer_rejected = optimized_result, optimized_iou, False
    else:
        result, qc_iou, optimizer_rejected = non_degrading_affine_result(
            metrics["initialTransform"],
            optimized_result,
            initial_iou,
            optimized_iou,
        )
    transform_path = slice_dir / "atlas-to-slice-affine.tfm"
    sitk.WriteTransform(result, str(transform_path))

    track_candidates, legacy_detection = detect_probe_tracks(
        slice_record, prepared, slice_dir
    )
    for detection in track_candidates:
        detection["sliceCoordinateSpace"] = "canonicalOrientedSlicePixels"
        detection["sourceRasterOrientation"] = raster_orientation(pose)
        map_track_to_atlas(detection, result, pixel_size, plane, atlas)
    slice_record["probeTrackCandidates"] = track_candidates
    # Retain a legacy projection during the schema-1 transition.  New readers
    # must prefer probeTrackCandidates; the value is never used as a second
    # scientific observation.
    detection = track_candidates[0] if track_candidates else legacy_detection
    detection["sliceCoordinateSpace"] = "canonicalOrientedSlicePixels"
    detection["sourceRasterOrientation"] = raster_orientation(pose)
    if not detection.get("atlasPoints"):
        map_track_to_atlas(detection, result, pixel_size, plane, atlas)
    slice_record["probeTrack"] = detection
    registered_rgb = resample_rgb(prepared.rgb, pixel_size, fixed, result)
    write_registration_artifacts(
        slice_record,
        slice_dir,
        atlas,
        plane.center_ap_index,
        plane.gray,
        registered_rgb,
        plane.annotation,
        detection,
    )
    artifacts["transformPath"] = str(transform_path)

    transform_record = {
        "id": f"affine-{safe_name(str(slice_record.get('id')))}",
        "kind": "affine",
        "stage": "manual" if landmarks else "affine",
        "direction": "atlasToSlice",
        "engine": (
            "NumPy paired-landmark least squares + SimpleITK"
            if landmarks else f"SimpleITK {sitk.Version_VersionString()}"
        ),
        "affine": affine_json(result),
        "transformParametersPath": str(transform_path),
        "landmarks": [point.model_dump() for point in landmarks or []],
        "metric": None if optimizer_rejected or landmarks else float(metrics["metric"]),
        "createdAt": utc_now(),
        "provenance": (
            f"BrainGlobe {atlas.name} v{atlas.version}; "
            f"{'paired-landmark affine' if landmarks else 'Mattes MI affine'}; "
            f"atlas plane spacing={plane.spacing}; slice spacing={pixel_size:g}um; "
            f"pose={project.get('provenance', {}).get('poseEngine', 'project pose')}; "
            f"optimizer={'rejected for tissue-overlap regression' if optimizer_rejected else 'retained'}; "
            f"worker={WORKER_VERSION}"
        ),
        "coordinateUnit": "micron",
        "movingImageSpace": "canonicalOrientedSliceMicrons",
        "rasterOrientation": raster_orientation(pose),
    }
    transforms = slice_record.setdefault("transformChain", {}).setdefault(
        "transforms", []
    )
    transforms[:] = [entry for entry in transforms if entry.get("kind") != "affine"]
    transforms.append(transform_record)
    qc = slice_record.setdefault("qc", {})
    qc["landmarkRMSErrorMicrons"] = landmark_rms
    # Keep the legacy field for existing projects; this is whole-tissue overlap,
    # never a measurement of internal brain-region registration accuracy.
    qc["majorRegionIoU"] = float(qc_iou)
    qc["mutualInformationMetric"] = (
        None if optimizer_rejected or landmarks else float(metrics["metric"])
    )
    warnings = qc.setdefault("warnings", [])
    warnings[:] = [
        warning
        for warning in warnings
        if not warning.startswith("Affine tissue-mask IoU")
        and not warning.startswith("Affine optimization")
        and not warning.startswith("Manual landmark fit")
        and not warning.startswith(
            "Pose initialization used the BrainGlobe silhouette fallback"
        )
    ]
    pose_engine = str(project.get("provenance", {}).get("poseEngine", ""))
    used_silhouette_fallback = "silhouette fallback" in pose_engine.lower()
    if landmarks:
        warnings.append(
            f"Manual landmark fit RMS={landmark_rms:.2f} um in canonical slice space; "
            "this is an in-sample residual, not independent registration accuracy."
        )
        slice_record["status"] = "needsReview"
    elif used_silhouette_fallback:
        warnings.append(
            "Pose initialization used the BrainGlobe silhouette fallback rather than DeepSlice; "
            "verify the AP plane and angle before acceptance."
        )
        slice_record["status"] = "needsReview"
    elif optimizer_rejected:
        warnings.append(
            f"Affine optimization candidate reduced tissue-mask IoU "
            f"({initial_iou:.3f} to {optimized_iou:.3f}); retained the better "
            "pose initialization and require manual review."
        )
        slice_record["status"] = "needsReview"
    elif qc_iou < 0.55:
        warnings.append(
            f"Affine tissue-mask IoU is low ({qc_iou:.3f}); manual review required."
        )
        slice_record["status"] = "needsReview"
    elif float(plane.mask.mean()) > 0.96:
        warnings.append(
            f"DeepSlice atlas plane is almost entirely inside annotated brain ({plane.mask.mean():.3f} coverage); verify crop/angle."
        )
        slice_record["status"] = "needsReview"
    elif any(warning.startswith("DeepSlice pose adjustment") for warning in warnings):
        slice_record["status"] = "needsReview"
    else:
        slice_record["status"] = "affineDone"
    slice_record["reviewNotes"] = (
        f"SimpleITK affine complete. Tissue-mask IoU={qc_iou:.3f} "
        f"(initial {initial_iou:.3f}, optimized candidate {optimized_iou:.3f}, "
        f"optimizer {'rejected' if optimizer_rejected else 'retained'}); "
        f"optimizer={metrics['stop']}"
    )
    if landmarks:
        slice_record["reviewNotes"] = (
            f"Manual affine correction from {len(landmarks)} paired landmarks; "
            f"fit RMS={landmark_rms:.2f} um; tissue-mask IoU={qc_iou:.3f}. "
            "Review the corrected overlay before acceptance; fit RMS is not accuracy."
        )
    return slice_record


def command_prepare(args: argparse.Namespace) -> dict[str, Any]:
    project = read_json(args.project)
    total = len(project.get("slices", []))
    emit_progress(args, "preparing", 0, total, f"Preparing {total} section raster(s).")
    result = prepare_project(project, args.out)
    emit_progress(
        args, "completed", total, total, f"Prepared {total} section raster(s)."
    )
    return result


def command_estimate_pose(args: argparse.Namespace) -> dict[str, Any]:
    project = read_json(args.project)
    require_montage_source(project)
    total = len(project.get("slices", []))
    emit_progress(
        args, "loadingAtlas", 0, total, "Loading the Allen atlas for pose estimation."
    )
    atlas = load_atlas(project, annotations=True)
    emit_progress(
        args,
        "estimatingPose",
        0,
        total,
        f"Estimating atlas pose for {total} section(s).",
    )
    project = estimate_poses(project, atlas, args.out)
    args.out.mkdir(parents=True, exist_ok=True)
    output = args.out / "poses.json"
    write_json(output, project)
    emit_progress(
        args, "completed", total, total, f"Estimated atlas pose for {total} section(s)."
    )
    return result_envelope(
        "estimate-pose",
        "ok",
        project,
        output,
        [
            f"Estimated atlas poses for {len(project.get('slices', []))} section(s) with "
            f"{project.get('provenance', {}).get('poseEngine', 'BrainGlobe')} and {atlas.name}."
        ],
    )


def command_register_slice(args: argparse.Namespace) -> dict[str, Any]:
    project = read_json(args.project)
    require_montage_source(project)
    matches = [
        item for item in project.get("slices", []) if item.get("id") == args.slice_id
    ]
    if not matches:
        raise WorkerBlocked(f"No registration slice found for {args.slice_id}.")
    emit_progress(
        args, "loadingAtlas", 0, 1, "Loading the Allen atlas for registration."
    )
    atlas = load_atlas(project, annotations=True)
    emit_progress(
        args,
        "registeringSlices",
        0,
        1,
        f"Registering {matches[0].get('title') or args.slice_id}.",
        slice_record=matches[0],
    )
    updated = register_one_slice(
        project, matches[0], args.stage, args.out, atlas, RegistrationConfig()
    )
    project["updatedAt"] = utc_now()
    output = args.out / f"{safe_name(args.slice_id)}-{args.stage}-registration.json"
    write_json(output, updated)
    write_json(args.out / "project.json", project)
    emit_progress(
        args,
        "completed",
        1,
        1,
        f"Registered {updated.get('title') or args.slice_id}.",
        slice_record=updated,
    )
    return result_envelope(
        "register-slice",
        "ok",
        project,
        output,
        [
            f"Registered {args.slice_id} to {atlas.name} with a real SimpleITK affine transform."
        ],
        slice_record=updated,
    )


def command_register_project(args: argparse.Namespace) -> dict[str, Any]:
    project = read_json(args.project)
    require_montage_source(project)
    slices = project.get("slices", [])
    total = len(slices)
    emit_progress(
        args, "loadingAtlas", 0, total, "Loading the Allen atlas for registration."
    )
    atlas = load_atlas(project, annotations=True)
    if any(not item.get("pose") for item in slices):
        emit_progress(
            args,
            "estimatingPose",
            0,
            total,
            f"Estimating atlas pose for {total} section(s).",
        )
        project = estimate_poses(project, atlas, args.out)
    registered = 0
    failed = 0
    for index, slice_record in enumerate(slices):
        title = str(
            slice_record.get("title")
            or slice_record.get("id")
            or f"Section {index + 1}"
        )
        emit_progress(
            args,
            "registeringSlices",
            index,
            total,
            f"Registering {title} ({index + 1} of {total}).",
            slice_record=slice_record,
            failed=failed,
        )
        try:
            register_one_slice(
                project, slice_record, args.stage, args.out, atlas, RegistrationConfig()
            )
            registered += 1
        except (WorkerBlocked, RuntimeError, ValueError) as error:
            failed += 1
            slice_record["status"] = "failed"
            slice_record.setdefault("qc", {}).setdefault("warnings", []).append(
                str(error)
            )
            slice_record["reviewNotes"] = str(error)
        emit_progress(
            args,
            "registeringSlices",
            index + 1,
            total,
            f"Finished {title} ({index + 1} of {total}); {failed} failed.",
            slice_record=slice_record,
            failed=failed,
        )
    project["updatedAt"] = utc_now()
    emit_progress(
        args,
        "finalizing",
        total,
        total,
        f"Saving registration results for {registered} successful and {failed} failed section(s).",
        failed=failed,
    )
    output = args.out / "registered-project.json"
    write_json(output, project)
    stage = "ok" if registered > 0 else "failed"
    messages = [
        f"Registered {registered}/{registered + failed} section(s) with SimpleITK affine registration."
    ]
    if failed:
        messages.append(
            f"{failed} section(s) failed and remain individually retryable."
        )
    emit_progress(
        args,
        "completed" if stage == "ok" else "failed",
        total,
        total,
        f"Registration finished: {registered} successful, {failed} failed.",
        failed=failed,
    )
    return result_envelope("register-project", stage, project, output, messages)


def command_correct_slice(args: argparse.Namespace) -> dict[str, Any]:
    project = read_json(args.project)
    require_montage_source(project)
    context = project.get("brain3dContext")
    if project.get("blindReviewLocked") is True or (
        isinstance(context, dict) and context.get("blindReviewLocked") is True
    ):
        raise WorkerBlocked("Unlock blind review before changing atlas registration.")
    matches = [item for item in project["slices"] if item["id"] == args.slice_id]
    if len(matches) != 1:
        raise WorkerBlocked(f"Expected one registration slice for {args.slice_id}.")
    try:
        correction = SliceCorrection.model_validate_json(args.correction_json.read_text())
    except (OSError, ValidationError) as error:
        raise WorkerBlocked(f"Could not read slice correction: {error}") from error
    if 0 < len(correction.landmarks) < 3:
        raise WorkerBlocked(
            "Provide no landmarks for plane correction, or at least three paired landmarks."
        )
    slice_record = matches[0]
    prior_pose = slice_record.get("pose")
    if not prior_pose:
        raise WorkerBlocked("Estimate an atlas pose before manual correction.")
    prior_angles = prior_pose.get("atlasSlicingAngles") or {}
    if correction.landmarks and (
        abs(correction.atlasAPMicrons - float(prior_pose["atlasAPMicrons"])) > 1e-6
        or abs(correction.pitchDegrees - float(prior_angles.get("pitchDegrees", 0))) > 1e-6
        or abs(correction.yawDegrees - float(prior_angles.get("rollDegrees", 0))) > 1e-6
    ):
        raise WorkerBlocked(
            "Apply the changed atlas plane first, then select landmarks on its updated reference image."
        )
    slice_dir = args.out / "slices" / safe_name(args.slice_id)
    if slice_dir.exists() or (args.out / "project.json").exists():
        raise WorkerBlocked(
            "Manual correction requires a new output run; existing registration files are preserved."
        )
    emit_progress(args, "loadingAtlas", 0, 1, "Loading atlas for manual correction.")
    atlas = load_atlas(project, annotations=True)
    pose = corrected_pose(prior_pose, correction, atlas)
    args.out.mkdir(parents=True, exist_ok=True)
    write_json(args.out / "prior-slice.json", slice_record)
    write_json(args.out / "applied-correction.json", correction.model_dump())
    install_pose(slice_record, pose, engine="Manual QuickNII plane correction")
    emit_progress(
        args, "registeringSlices", 0, 1, "Applying manual correction.",
        slice_record=slice_record,
    )
    updated = register_one_slice(
        project, slice_record, "affine", args.out, atlas, RegistrationConfig(),
        landmarks=correction.landmarks,
    )
    updated["status"] = "needsReview"
    project["blindReviewLocked"] = False
    project.pop("blindTrackReview", None)
    project.pop("blindTrackReviewPreview", None)
    if isinstance(context, dict):
        context["blindReviewLocked"] = False
        context["reviewDispositions"] = []
        context.pop("reviewPreview", None)
    project["updatedAt"] = utc_now()
    output = args.out / f"{safe_name(args.slice_id)}-corrected.json"
    write_json(output, updated)
    write_json(args.out / "project.json", project)
    emit_progress(
        args, "completed", 1, 1, "Manual correction is ready for review.",
        slice_record=updated,
    )
    return result_envelope(
        "correct-slice", "ok", project, output,
        [
            "Manual correction saved to a new run; "
            "slice acceptance and downstream track review were cleared."
        ],
        slice_record=updated,
    )


def valid_affine_transform_record(transform_record: dict[str, Any]) -> bool:
    if transform_record.get("kind") != "affine":
        return False
    if transform_record.get("direction") != "atlasToSlice":
        return False
    if transform_record.get("coordinateUnit") != "micron":
        return False
    affine = transform_record.get("affine") or {}
    try:
        values = np.asarray(
            [affine[name] for name in ("m00", "m01", "m10", "m11", "tx", "ty")],
            dtype=np.float64,
        )
        determinant = float(values[0] * values[3] - values[1] * values[2])
    except (KeyError, TypeError, ValueError):
        return False
    parameter_path = transform_record.get("transformParametersPath")
    if (
        not np.all(np.isfinite(values))
        or abs(determinant) <= 1e-9
        or not parameter_path
    ):
        return False
    path = Path(parameter_path)
    if not path.is_file():
        return False
    try:
        parsed = sitk.ReadTransform(str(path))
        if parsed.GetDimension() != 2:
            return False
        parsed_values = affine_json(parsed)
        parsed_array = np.asarray(
            [parsed_values[name] for name in ("m00", "m01", "m10", "m11", "tx", "ty")],
            dtype=np.float64,
        )
    except (RuntimeError, ValueError, OSError):
        return False
    return bool(np.allclose(values, parsed_array, rtol=1e-7, atol=1e-4))


def has_quantitative_transform(slice_record: dict[str, Any]) -> bool:
    for transform_record in slice_record.get("transformChain", {}).get(
        "transforms", []
    ):
        if valid_affine_transform_record(transform_record):
            return True
    return False


def validate_registration_artifacts(
    slice_record: dict[str, Any], atlas: AtlasData | None = None
) -> list[str]:
    errors: list[str] = []
    slice_id = str(slice_record.get("id", "slice"))
    artifacts = artifact_record(slice_record)
    transform_path = artifacts.get("transformPath")
    usable = [
        item
        for item in slice_record.get("transformChain", {}).get("transforms", [])
        if valid_affine_transform_record(item)
    ]
    if not usable:
        errors.append(
            f"{slice_id}: no parseable affine transform matching its JSON matrix"
        )
    elif (
        not transform_path
        or Path(transform_path).resolve()
        != Path(usable[-1]["transformParametersPath"]).resolve()
    ):
        errors.append(
            f"{slice_id}: artifact transformPath does not match the transform chain"
        )

    annotation_path = artifacts.get("annotationImagePath")
    boundary_path = artifacts.get("boundaryImagePath")
    if not annotation_path or not boundary_path:
        errors.append(f"{slice_id}: annotation or boundary artifact is missing")
        return errors
    try:
        annotation = np.asarray(tifffile.imread(annotation_path))
        if (
            annotation.ndim != 2
            or min(annotation.shape) < 16
            or not np.issubdtype(annotation.dtype, np.integer)
        ):
            raise ValueError(
                f"invalid annotation shape/dtype {annotation.shape}/{annotation.dtype}"
            )
    except (OSError, ValueError, tifffile.TiffFileError) as error:
        errors.append(f"{slice_id}: annotation TIFF is not valid ({error})")
        return errors
    try:
        with Image.open(boundary_path) as boundary_image:
            boundary_image.verify()
        with Image.open(boundary_path) as boundary_image:
            boundary_shape = (boundary_image.height, boundary_image.width)
        if boundary_shape != annotation.shape:
            raise ValueError(
                f"boundary {boundary_shape} != annotation {annotation.shape}"
            )
    except (OSError, ValueError) as error:
        errors.append(f"{slice_id}: boundary image is not valid ({error})")

    if atlas is not None:
        known_ids = {0}
        try:
            known_ids.update(int(value) for value in atlas.structures.keys())
        except AttributeError:
            pass
        unknown = set(int(value) for value in np.unique(annotation)) - known_ids
        if unknown:
            errors.append(
                f"{slice_id}: annotation contains unknown atlas IDs {sorted(unknown)[:5]}"
            )
    return errors


def project_blockers(project: dict[str, Any]) -> list[str]:
    blockers: list[str] = []
    pixel_size = project.get("pixelSizeMicrons")
    if pixel_size is None or not 0.1 <= float(pixel_size) <= 100.0:
        blockers.append("Missing or implausible physical pixel size calibration.")
    invalid_slice_calibration = [
        item
        for item in project.get("slices", [])
        if item.get("pixelSizeMicrons") is None
        or not 0.1 <= float(item.get("pixelSizeMicrons")) <= 100.0
    ]
    if invalid_slice_calibration:
        blockers.append(
            f"{len(invalid_slice_calibration)} slice(s) are missing a valid per-section pixel calibration."
        )
    if project.get("orientation") != "coronal":
        blockers.append("Only adult mouse coronal sections are supported.")
    atlas = project.get("atlas") or {}
    if (
        atlas.get("id") != ATLAS_NAME
        or str(atlas.get("version")) != ATLAS_VERSION
        or float(atlas.get("voxelSizeMicrons", 0)) != 25.0
    ):
        blockers.append(
            f"Atlas must be {ATLAS_NAME} v{ATLAS_VERSION} at 25 um for this worker."
        )
    if project.get("sourceMode") != "montageSections":
        blockers.append(
            "Acquisition-tile preview mode cannot be exported as serial histology."
        )
    structural_count = sum(
        item.get("role") == "structural" for item in project.get("channelMappings", [])
    )
    probe_count = sum(
        item.get("role") == "probeTrack" for item in project.get("channelMappings", [])
    )
    if structural_count != 1:
        blockers.append(
            f"Project must have exactly one structural registration channel; found {structural_count}."
        )
    if probe_count > 1:
        blockers.append(
            f"Project has {probe_count} probe-track channels; at most one is supported."
        )
    slices = project.get("slices", [])
    if not slices:
        blockers.append("Project has no slices.")
    unaccepted = [item for item in slices if item.get("status") != "accepted"]
    if unaccepted:
        blockers.append(f"{len(unaccepted)} slice(s) are not accepted after review.")
    missing = [
        item
        for item in slices
        if item.get("status") == "accepted" and not has_quantitative_transform(item)
    ]
    if missing:
        blockers.append(
            f"{len(missing)} accepted slice(s) do not have a usable on-disk affine transform."
        )
    invalid_artifacts = [
        item
        for item in slices
        if item.get("status") == "accepted" and validate_registration_artifacts(item)
    ]
    if invalid_artifacts:
        blockers.append(
            f"{len(invalid_artifacts)} accepted slice(s) have invalid transform/annotation/boundary artifacts."
        )
    return blockers


def accepted_track_points(
    project: dict[str, Any],
) -> tuple[np.ndarray, list[dict[str, Any]]]:
    records: list[dict[str, Any]] = []
    coordinates: list[list[float]] = []
    for slice_record in project.get("slices", []):
        if slice_record.get("status") != "accepted":
            continue
        candidates = slice_record.get("probeTrackCandidates")
        if candidates is None:
            legacy = slice_record.get("probeTrack")
            candidates = [legacy] if isinstance(legacy, dict) else []
        elif not isinstance(candidates, list):
            raise WorkerBlocked(
                f"Slice {slice_record.get('id')} probeTrackCandidates must be an array."
            )
        if len(candidates) > MAX_SLICE_TRACK_CANDIDATES:
            raise WorkerBlocked(
                f"Slice {slice_record.get('id')} exceeds the "
                f"{MAX_SLICE_TRACK_CANDIDATES}-candidate blind track limit."
            )
        for candidate_index, detection in enumerate(candidates):
            if (
                not isinstance(detection, dict)
                or detection.get("reviewAccepted") is not True
            ):
                continue
            candidate_id = str(
                detection.get("candidateId")
                or f"{safe_name(str(slice_record.get('id', 'slice')))}-legacy-{candidate_index + 1}"
            )
            atlas_points = detection.get("atlasPoints") or []
            source_points = {
                (
                    round(float(point.get("x", 0.0)), 9),
                    round(float(point.get("y", 0.0)), 9),
                ): point
                for point in detection.get("points", [])
                if isinstance(point, dict)
            }
            for point_index, point in enumerate(atlas_points):
                coordinates.append(
                    [
                        float(point["apMicrons"]),
                        float(point["dorsalVentralMicrons"]),
                        float(point["rightLeftMicrons"]),
                    ]
                )
                slice_point = point.get("slicePoint") or {}
                source_point = source_points.get(
                    (
                        round(float(slice_point.get("x", 0.0)), 9),
                        round(float(slice_point.get("y", 0.0)), 9),
                    ),
                    {},
                )
                source_point_id = str(
                    source_point.get("pointId")
                    or f"{candidate_id}-atlas-point-{point_index + 1:04d}"
                )
                records.append(
                    {
                        "sliceID": slice_record.get("id"),
                        "candidateID": candidate_id,
                        "sourcePointID": source_point_id,
                        **point,
                    }
                )
    return np.asarray(coordinates, dtype=np.float64), records


def reconstruct_probe_track(
    project: dict[str, Any], atlas: AtlasData, out: Path
) -> tuple[str | None, str | None]:
    points, source_records = accepted_track_points(project)
    distinct_slice_ids = {str(record.get("sliceID")) for record in source_records}
    if points.shape[0] < 3 or len(distinct_slice_ids) < 2:
        return None, None
    model, inliers = measure.ransac(
        points,
        measure.LineModelND,
        min_samples=2,
        residual_threshold=100.0,
        max_trials=1000,
        rng=RANDOM_SEED,
    )
    if model is None or inliers is None or int(inliers.sum()) < 3:
        return None, None
    origin = np.asarray(model.origin, dtype=np.float64)
    direction = np.asarray(model.direction, dtype=np.float64)
    inlier_points = points[inliers]
    projections = (inlier_points - origin) @ direction
    start_projection = float(projections.min())
    end_projection = float(projections.max())
    length = max(0.0, end_projection - start_projection)
    count = max(2, int(math.floor(length / 20.0)) + 1)
    sample_projections = np.linspace(start_projection, end_projection, count)
    samples = origin[None, :] + sample_projections[:, None] * direction[None, :]
    annotation = atlas.require_annotation()

    site_rows: list[dict[str, Any]] = []
    for site_index, coordinate in enumerate(samples):
        indices = np.rint(coordinate / np.asarray(atlas.resolution)).astype(int)
        inside = bool(
            np.all(indices >= 0) and np.all(indices < np.asarray(annotation.shape))
        )
        structure_id = int(annotation[tuple(indices)]) if inside else 0
        region = structure_info(atlas, structure_id)
        site_rows.append(
            {
                "site_index": site_index,
                "distance_um": float(sample_projections[site_index] - start_projection),
                "ap_um": float(coordinate[0]),
                "dv_um": float(coordinate[1]),
                "rl_um": float(coordinate[2]),
                "structure_id": structure_id,
                "acronym": region["acronym"],
                "region_name": region["name"],
            }
        )

    sites_path = out / "trajectory-samples.csv"
    with sites_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(site_rows[0].keys()))
        writer.writeheader()
        writer.writerows(site_rows)
    track_path = out / "probe-track.json"
    write_json(
        track_path,
        {
            "atlas": atlas.name,
            "coordinateOrder": ["anteriorPosterior", "dorsalVentral", "rightLeft"],
            "coordinateUnit": "micron",
            "origin": origin.tolist(),
            "direction": direction.tolist(),
            "start": samples[0].tolist(),
            "end": samples[-1].tolist(),
            "lengthMicrons": length,
            "inlierCount": int(inliers.sum()),
            "pointCount": int(points.shape[0]),
            "distinctSliceCount": len(distinct_slice_ids),
            "sourcePoints": source_records,
            "siteAssignmentsPath": sites_path.name,
            "algorithm": f"scikit-image LineModelND RANSAC seed={RANDOM_SEED}",
        },
    )
    return track_path.name, sites_path.name


def _canonical_undirected_direction(direction: np.ndarray) -> np.ndarray:
    normalized = np.asarray(direction, dtype=np.float64)
    norm = float(np.linalg.norm(normalized))
    if not math.isfinite(norm) or norm <= 1e-12:
        raise WorkerBlocked("Probe-track fit produced a zero or non-finite direction.")
    normalized = normalized / norm
    for component in normalized:
        if abs(float(component)) <= 1e-12:
            continue
        if component < 0:
            normalized = -normalized
        break
    return normalized


def _leave_one_section_out_sensitivity(
    points: np.ndarray,
    source_records: list[dict[str, Any]],
    full_origin: np.ndarray,
    full_direction: np.ndarray,
) -> dict[str, Any]:
    """Measure deterministic line-fit sensitivity to omitting each section.

    This is descriptive retrospective fit QC.  It is deliberately not an
    acceptance threshold, probability, navigation metric, or safety claim.
    """

    slice_ids = sorted({str(record.get("sliceID")) for record in source_records})
    if len(slice_ids) < 3:
        return {
            "available": False,
            "reason": "requires at least 3 distinct accepted slices",
            "usableForNavigation": False,
        }
    if (
        points.ndim != 2
        or points.shape[1:] != (3,)
        or points.shape[0] != len(source_records)
        or not np.all(np.isfinite(points))
        or np.asarray(full_origin).shape != (3,)
        or not np.all(np.isfinite(full_origin))
        or np.asarray(full_direction).shape != (3,)
        or not np.all(np.isfinite(full_direction))
    ):
        raise WorkerBlocked(
            "Leave-one-section-out sensitivity requires aligned finite ASR points and a finite full fit."
        )

    record_slice_ids = np.asarray(
        [str(record.get("sliceID")) for record in source_records],
        dtype=object,
    )
    omissions: list[dict[str, Any]] = []
    for omitted_slice_id in slice_ids:
        retained = record_slice_ids != omitted_slice_id
        held_out = ~retained
        retained_points = points[retained]
        held_out_points = points[held_out]
        # Three source sections guarantee two retained sections, but a
        # malformed reviewed set could still contain fewer than two points.
        if retained_points.shape[0] < 2 or held_out_points.shape[0] < 1:
            return {
                "available": False,
                "reason": "each leave-one-section-out refit requires retained and held-out points",
                "usableForNavigation": False,
            }

        refit_origin = retained_points.mean(axis=0)
        _, _, right_vectors = np.linalg.svd(
            retained_points - refit_origin,
            full_matrices=False,
        )
        refit_direction = _canonical_undirected_direction(
            np.asarray(right_vectors[0], dtype=np.float64)
        )
        absolute_dot = float(
            np.clip(abs(float(np.dot(full_direction, refit_direction))), 0.0, 1.0)
        )
        axis_angle = (
            0.0
            if 1.0 - absolute_dot <= 1e-12
            else math.degrees(math.acos(absolute_dot))
        )
        line_separation = _line_separation(
            full_origin,
            full_direction,
            refit_origin,
            refit_direction,
        )
        held_out_delta = held_out_points - refit_origin
        held_out_projections = held_out_delta @ refit_direction
        held_out_residuals = np.linalg.norm(
            held_out_delta - np.outer(held_out_projections, refit_direction),
            axis=1,
        )
        held_out_rmse = float(np.sqrt(np.mean(np.square(held_out_residuals))))
        if not all(
            math.isfinite(value)
            for value in (axis_angle, line_separation, held_out_rmse)
        ):
            raise WorkerBlocked(
                "Leave-one-section-out sensitivity produced a non-finite fit metric."
            )
        omissions.append(
            {
                "omittedSliceId": omitted_slice_id,
                "retainedPointCount": int(retained_points.shape[0]),
                "heldOutPointCount": int(held_out_points.shape[0]),
                "axisAngleDegrees": axis_angle,
                "lineSeparationMicrometres": line_separation,
                "heldOutRMSEMicrometres": held_out_rmse,
            }
        )

    return {
        "available": True,
        "method": "deterministic-pca-line-refit-leave-one-section-out-v1",
        "omissionCount": len(omissions),
        "maximumAxisAngleDegrees": max(item["axisAngleDegrees"] for item in omissions),
        "maximumLineSeparationMicrometres": max(
            item["lineSeparationMicrometres"] for item in omissions
        ),
        "rmsHeldOutResidualMicrometres": math.sqrt(
            sum(item["heldOutRMSEMicrometres"] ** 2 for item in omissions)
            / len(omissions)
        ),
        "omissions": omissions,
        "usableForNavigation": False,
    }


@dataclass(frozen=True)
class BlindTrackPartition:
    """A closed-world partition of every accepted blind source point."""

    groups: tuple[tuple[str, tuple[int, ...]], ...]
    unassigned_indices: tuple[int, ...]
    review_state: dict[str, Any]
    review_state_sha256: str
    is_explicit_review: bool


def _validated_blind_source_points(
    project: dict[str, Any],
) -> tuple[np.ndarray, list[dict[str, Any]]]:
    """Return a stable, finite, uniquely identified blind point set."""

    points, source_records = accepted_track_points(project)
    if not source_records:
        return np.empty((0, 3), dtype=np.float64), []
    if points.shape != (len(source_records), 3) or not np.all(np.isfinite(points)):
        raise WorkerBlocked(
            "Blind track review requires aligned finite BrainGlobe ASR source points."
        )
    source_ids = [str(record.get("sourcePointID") or "") for record in source_records]
    if any(not source_id for source_id in source_ids):
        raise WorkerBlocked(
            "Every accepted blind source point must have a stable non-empty ID."
        )
    if len(set(source_ids)) != len(source_ids):
        raise WorkerBlocked("Accepted blind source-point IDs must be unique.")
    order = np.argsort(np.asarray(source_ids, dtype=object), kind="stable")
    return points[order], [source_records[int(index)] for index in order]


def _normalized_blind_track_review(
    raw_review: Any,
    source_records: list[dict[str, Any]],
) -> BlindTrackPartition:
    """Validate the explicit schema-1 review as one exact source-point partition."""

    if not isinstance(raw_review, dict):
        raise WorkerBlocked("blindTrackReview must be a schema-1 object.")
    expected_keys = {
        "schemaVersion",
        "groups",
        "unassignedSourcePointIDs",
        "usableForNavigation",
    }
    if set(raw_review) != expected_keys:
        missing = sorted(expected_keys - set(raw_review))
        unknown = sorted(set(raw_review) - expected_keys)
        raise WorkerBlocked(
            "blindTrackReview has an invalid exact member set"
            f" (missing={missing}, unknown={unknown})."
        )
    schema_version = raw_review.get("schemaVersion")
    if (
        isinstance(schema_version, bool)
        or not isinstance(schema_version, int)
        or schema_version != BLIND_TRACK_REVIEW_SCHEMA_VERSION
    ):
        raise WorkerBlocked(
            f"blindTrackReview.schemaVersion must be {BLIND_TRACK_REVIEW_SCHEMA_VERSION}."
        )
    if raw_review.get("usableForNavigation") is not False:
        raise WorkerBlocked("blindTrackReview.usableForNavigation must be false.")
    raw_groups = raw_review.get("groups")
    raw_unassigned = raw_review.get("unassignedSourcePointIDs")
    if not isinstance(raw_groups, list):
        raise WorkerBlocked("blindTrackReview.groups must be an array.")
    if len(raw_groups) > MAX_RECONSTRUCTED_TRACKS:
        raise WorkerBlocked(
            f"blindTrackReview exceeds the {MAX_RECONSTRUCTED_TRACKS}-track limit."
        )
    if not isinstance(raw_unassigned, list):
        raise WorkerBlocked(
            "blindTrackReview.unassignedSourcePointIDs must be an array."
        )

    source_index_by_id = {
        str(record["sourcePointID"]): index
        for index, record in enumerate(source_records)
    }
    group_ids: set[str] = set()
    assigned_source_ids: set[str] = set()
    normalized_groups: list[dict[str, Any]] = []
    indexed_groups: list[tuple[str, tuple[int, ...]]] = []
    for group_index, raw_group in enumerate(raw_groups):
        if not isinstance(raw_group, dict) or set(raw_group) != {
            "groupId",
            "sourcePointIDs",
        }:
            raise WorkerBlocked(
                f"blindTrackReview.groups[{group_index}] must contain only groupId and sourcePointIDs."
            )
        group_id_value = raw_group.get("groupId")
        if (
            not isinstance(group_id_value, str)
            or not group_id_value.strip()
            or len(group_id_value) > 200
        ):
            raise WorkerBlocked(
                f"blindTrackReview.groups[{group_index}].groupId must be a non-empty string up to 200 characters."
            )
        group_id = group_id_value.strip()
        if group_id != group_id_value:
            raise WorkerBlocked(
                f"blindTrackReview.groups[{group_index}].groupId cannot have surrounding whitespace."
            )
        if group_id in group_ids:
            raise WorkerBlocked("blindTrackReview group IDs must be unique.")
        group_ids.add(group_id)
        raw_source_ids = raw_group.get("sourcePointIDs")
        if not isinstance(raw_source_ids, list) or len(raw_source_ids) < 3:
            raise WorkerBlocked(
                f"Blind track review group {group_id!r} requires at least 3 source points."
            )
        if any(not isinstance(value, str) or not value for value in raw_source_ids):
            raise WorkerBlocked(
                f"Blind track review group {group_id!r} contains an invalid source-point ID."
            )
        source_ids = sorted(raw_source_ids)
        if len(set(source_ids)) != len(source_ids):
            raise WorkerBlocked(
                f"Blind track review group {group_id!r} contains duplicate source-point IDs."
            )
        unknown = sorted(set(source_ids) - set(source_index_by_id))
        if unknown:
            raise WorkerBlocked(
                f"Blind track review group {group_id!r} references unknown source-point IDs: {unknown[:5]}."
            )
        overlap = sorted(set(source_ids) & assigned_source_ids)
        if overlap:
            raise WorkerBlocked(
                "Blind track review source points cannot belong to more than one group: "
                f"{overlap[:5]}."
            )
        assigned_source_ids.update(source_ids)
        group_indices = tuple(source_index_by_id[source_id] for source_id in source_ids)
        distinct_slice_ids = {
            str(source_records[index].get("sliceID")) for index in group_indices
        }
        if len(distinct_slice_ids) < 2:
            raise WorkerBlocked(
                f"Blind track review group {group_id!r} must span at least 2 accepted slices."
            )
        normalized_groups.append({"groupId": group_id, "sourcePointIDs": source_ids})
        indexed_groups.append((group_id, group_indices))

    if any(not isinstance(value, str) or not value for value in raw_unassigned):
        raise WorkerBlocked(
            "blindTrackReview.unassignedSourcePointIDs contains an invalid source-point ID."
        )
    unassigned_source_ids = sorted(raw_unassigned)
    if len(set(unassigned_source_ids)) != len(unassigned_source_ids):
        raise WorkerBlocked(
            "Blind track review unassigned source-point IDs must be unique."
        )
    unknown_unassigned = sorted(set(unassigned_source_ids) - set(source_index_by_id))
    if unknown_unassigned:
        raise WorkerBlocked(
            "Blind track review references unknown unassigned source-point IDs: "
            f"{unknown_unassigned[:5]}."
        )
    overlap = sorted(set(unassigned_source_ids) & assigned_source_ids)
    if overlap:
        raise WorkerBlocked(
            "Blind track review source points cannot be both grouped and unassigned: "
            f"{overlap[:5]}."
        )
    reviewed_source_ids = assigned_source_ids | set(unassigned_source_ids)
    omitted = sorted(set(source_index_by_id) - reviewed_source_ids)
    if omitted:
        raise WorkerBlocked(
            "Blind track review must explicitly group or leave unassigned every accepted source point; "
            f"omitted: {omitted[:5]}."
        )

    normalized_groups.sort(key=lambda item: str(item["groupId"]))
    indexed_groups.sort(key=lambda item: item[0])
    normalized_review = {
        "schemaVersion": BLIND_TRACK_REVIEW_SCHEMA_VERSION,
        "groups": normalized_groups,
        "unassignedSourcePointIDs": unassigned_source_ids,
        "usableForNavigation": False,
    }
    return BlindTrackPartition(
        groups=tuple(indexed_groups),
        unassigned_indices=tuple(
            source_index_by_id[source_id] for source_id in unassigned_source_ids
        ),
        review_state=normalized_review,
        review_state_sha256=canonical_json_sha256(normalized_review),
        is_explicit_review=True,
    )


def _automatic_blind_track_partition(
    points: np.ndarray,
    source_records: list[dict[str, Any]],
) -> BlindTrackPartition:
    """Create a deterministic editable draft partition without any plan context."""

    remaining = np.ones(points.shape[0], dtype=bool)
    permanently_unassigned = np.zeros(points.shape[0], dtype=bool)
    indexed_groups: list[tuple[str, tuple[int, ...]]] = []
    while int(remaining.sum()) >= 3 and len(indexed_groups) < MAX_RECONSTRUCTED_TRACKS:
        indices = np.flatnonzero(remaining)
        model, local_inliers = measure.ransac(
            points[indices],
            measure.LineModelND,
            min_samples=2,
            residual_threshold=TRACK_RANSAC_RESIDUAL_UM,
            max_trials=1000,
            rng=RANDOM_SEED + len(indexed_groups),
        )
        if model is None or local_inliers is None or int(local_inliers.sum()) < 3:
            break
        fitted_indices = indices[np.flatnonzero(local_inliers)]
        distinct_slice_ids = {
            str(source_records[int(index)].get("sliceID")) for index in fitted_indices
        }
        if len(distinct_slice_ids) < 2:
            remaining[fitted_indices] = False
            permanently_unassigned[fitted_indices] = True
            continue
        source_ids = sorted(
            str(source_records[int(index)]["sourcePointID"]) for index in fitted_indices
        )
        group_digest = canonical_json_sha256({"sourcePointIDs": source_ids})
        indexed_groups.append(
            (
                f"auto-group-{group_digest[:16]}",
                tuple(int(index) for index in fitted_indices),
            )
        )
        remaining[fitted_indices] = False

    if len(indexed_groups) >= MAX_RECONSTRUCTED_TRACKS and int(remaining.sum()) >= 3:
        raise WorkerBlocked(
            f"Blind reconstruction exceeded the {MAX_RECONSTRUCTED_TRACKS}-track limit."
        )
    unassigned_indices = tuple(
        int(index) for index in np.flatnonzero(remaining | permanently_unassigned)
    )
    indexed_groups.sort(key=lambda item: item[0])
    review_state = {
        "schemaVersion": BLIND_TRACK_REVIEW_SCHEMA_VERSION,
        "groups": [
            {
                "groupId": group_id,
                "sourcePointIDs": sorted(
                    str(source_records[index]["sourcePointID"])
                    for index in group_indices
                ),
            }
            for group_id, group_indices in indexed_groups
        ],
        "unassignedSourcePointIDs": sorted(
            str(source_records[index]["sourcePointID"]) for index in unassigned_indices
        ),
        "usableForNavigation": False,
    }
    return BlindTrackPartition(
        groups=tuple(indexed_groups),
        unassigned_indices=unassigned_indices,
        review_state=review_state,
        review_state_sha256=canonical_json_sha256(review_state),
        is_explicit_review=False,
    )


def _blind_track_partition(
    project: dict[str, Any],
    points: np.ndarray,
    source_records: list[dict[str, Any]],
) -> BlindTrackPartition:
    if "blindTrackReview" in project:
        return _normalized_blind_track_review(
            project.get("blindTrackReview"), source_records
        )
    if project.get("blindReviewLocked") is True:
        raise WorkerBlocked(
            "A locked blind review requires an explicit complete blindTrackReview partition."
        )
    return _automatic_blind_track_partition(points, source_records)


def _fit_blind_track_group(
    group_id: str,
    group_indices: tuple[int, ...],
    points: np.ndarray,
    source_records: list[dict[str, Any]],
) -> dict[str, Any]:
    """Deterministically PCA-refit exactly one reviewed group without changing membership."""

    inlier_points = points[np.asarray(group_indices, dtype=np.int64)]
    track_source_records = [source_records[index] for index in group_indices]
    if inlier_points.shape[0] < 3:
        raise WorkerBlocked(
            f"Blind track review group {group_id!r} requires at least 3 points."
        )
    distinct_slice_ids = {str(record.get("sliceID")) for record in track_source_records}
    if len(distinct_slice_ids) < 2:
        raise WorkerBlocked(
            f"Blind track review group {group_id!r} must span at least 2 accepted slices."
        )
    origin = inlier_points.mean(axis=0)
    _, singular_values, right_vectors = np.linalg.svd(
        inlier_points - origin,
        full_matrices=False,
    )
    if (
        singular_values.size == 0
        or not math.isfinite(float(singular_values[0]))
        or singular_values[0] <= 1e-9
    ):
        raise WorkerBlocked(
            f"Blind track review group {group_id!r} cannot define a finite 3-D axis."
        )
    direction = _canonical_undirected_direction(
        np.asarray(right_vectors[0], dtype=np.float64)
    )
    projections = (inlier_points - origin) @ direction
    endpoint_a = origin + direction * float(projections.min())
    endpoint_b = origin + direction * float(projections.max())
    endpoint_a, endpoint_b = _canonical_undirected_endpoints(endpoint_a, endpoint_b)
    length = float(np.linalg.norm(endpoint_b - endpoint_a))
    if not math.isfinite(length) or length <= 1e-9:
        raise WorkerBlocked(
            f"Blind track review group {group_id!r} cannot define non-zero finite support."
        )
    residual_vectors = (inlier_points - origin) - np.outer(projections, direction)
    residuals = np.linalg.norm(residual_vectors, axis=1)
    rmse = float(np.sqrt(np.mean(np.square(residuals))))
    median_residual = float(np.median(residuals))
    maximum_residual = float(np.max(residuals))
    if not all(
        math.isfinite(value) for value in (rmse, median_residual, maximum_residual)
    ):
        raise WorkerBlocked(
            f"Blind track review group {group_id!r} produced non-finite fit QC."
        )
    source_ids = sorted(str(record["sourcePointID"]) for record in track_source_records)
    track_digest = canonical_json_sha256(
        {
            "algorithm": "deterministic-pca-finite-support-v1",
            "sourcePointIDs": source_ids,
            "endpointA": [round(float(value), 6) for value in endpoint_a],
            "endpointB": [round(float(value), 6) for value in endpoint_b],
            "axis": [round(float(value), 12) for value in direction],
        }
    )
    return {
        "groupId": group_id,
        "trackId": f"blind-track-{track_digest[:16]}",
        "fitDigest": track_digest,
        "coordinateFrame": "BRAINGLOBE_PHYSICAL_ASR_UM",
        "coordinateOrder": ["AP", "DV", "ML"],
        "endpointA": [float(value) for value in endpoint_a],
        "endpointB": [float(value) for value in endpoint_b],
        "axisUnitASR": [float(value) for value in direction],
        "directionSemantics": "undirected-canonical-sign-v1",
        "supportLengthMicrometres": length,
        "rmseMicrometres": rmse,
        "medianResidualMicrometres": median_residual,
        "maximumResidualMicrometres": maximum_residual,
        "inlierCount": len(group_indices),
        "pointCount": len(group_indices),
        "distinctSliceCount": len(distinct_slice_ids),
        "leaveOneSectionOutSensitivity": _leave_one_section_out_sensitivity(
            inlier_points,
            track_source_records,
            origin,
            direction,
        ),
        "sourcePointIDs": source_ids,
        "sourcePoints": track_source_records,
        "usableForNavigation": False,
    }


def reconstruct_probe_tracks(
    project: dict[str, Any],
    atlas: AtlasData,
    out: Path,
) -> tuple[str, str | None]:
    """Fit all explicitly reviewed blind tracks with exclusive point membership."""
    points, source_records = _validated_blind_source_points(project)
    partition = _blind_track_partition(project, points, source_records)
    tracks = [
        _fit_blind_track_group(group_id, group_indices, points, source_records)
        for group_id, group_indices in partition.groups
    ]
    site_rows: list[dict[str, Any]] = []
    annotation = atlas.require_annotation()
    for track_payload in tracks:
        track_id = str(track_payload["trackId"])
        endpoint_a = np.asarray(track_payload["endpointA"], dtype=np.float64)
        endpoint_b = np.asarray(track_payload["endpointB"], dtype=np.float64)
        length = float(track_payload["supportLengthMicrometres"])
        sample_count = max(2, int(math.floor(length / 20.0)) + 1)
        samples = np.linspace(endpoint_a, endpoint_b, sample_count)
        for sample_index, coordinate in enumerate(samples):
            voxel = np.floor(
                coordinate / np.asarray(atlas.resolution, dtype=np.float64)
            ).astype(int)
            inside = bool(
                np.all(voxel >= 0) and np.all(voxel < np.asarray(annotation.shape))
            )
            structure_id = int(annotation[tuple(voxel)]) if inside else 0
            region = structure_info(atlas, structure_id)
            site_rows.append(
                {
                    "track_id": track_id,
                    "sample_index": sample_index,
                    "distance_um": float(
                        length * sample_index / max(1, sample_count - 1)
                    ),
                    "ap_um": float(coordinate[0]),
                    "dv_um": float(coordinate[1]),
                    "ml_um": float(coordinate[2]),
                    "structure_id": structure_id,
                    "acronym": region["acronym"],
                    "region_name": region["name"],
                }
            )
    unassigned_ids = sorted(
        str(source_records[index]["sourcePointID"])
        for index in partition.unassigned_indices
    )
    reviewed_set_digest = canonical_json_sha256(
        {
            "sourcePointIDs": sorted(
                str(record.get("sourcePointID")) for record in source_records
            ),
            "tracks": sorted(
                (
                    {
                        "fitDigest": str(track["fitDigest"]),
                        "sourcePointIDs": list(track["sourcePointIDs"]),
                    }
                    for track in tracks
                ),
                key=lambda item: (str(item["fitDigest"]), item["sourcePointIDs"]),
            ),
            "unassignedSourcePointIDs": unassigned_ids,
        }
    )
    tracks_path = out / "probe-tracks.json"
    write_json(
        tracks_path,
        {
            "schemaVersion": PROBE_TRACKS_SCHEMA_VERSION,
            "atlas": atlas.name,
            "atlasVersion": atlas.version,
            "coordinateFrame": "BRAINGLOBE_PHYSICAL_ASR_UM",
            "coordinateOrder": ["AP", "DV", "ML"],
            "coordinateUnit": "micrometre",
            "blind": True,
            "reviewedTrackSetSha256": reviewed_set_digest,
            "reviewStateSha256": partition.review_state_sha256,
            "reviewState": partition.review_state,
            "algorithm": "deterministic-pca-finite-support-v1; exact reviewed source-point partition",
            "tracks": sorted(tracks, key=lambda item: str(item["trackId"])),
            "unassignedSourcePointIDs": unassigned_ids,
            "usableForNavigation": False,
        },
    )
    samples_path: Path | None = None
    if site_rows:
        samples_path = out / "trajectory-samples.csv"
        with samples_path.open("w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=list(site_rows[0].keys()))
            writer.writeheader()
            writer.writerows(
                sorted(
                    site_rows,
                    key=lambda item: (str(item["track_id"]), int(item["sample_index"])),
                )
            )
    return tracks_path.name, samples_path.name if samples_path is not None else None


def _asr_point(value: Any, *, field: str) -> np.ndarray:
    if isinstance(value, (list, tuple)) and len(value) == 3:
        point = np.asarray(value, dtype=np.float64)
    elif isinstance(value, dict):
        keys = (
            ("apMicrometres", "dvMicrometres", "mlMicrometres"),
            ("ap_um", "dv_um", "ml_um"),
            ("ap", "dv", "ml"),
        )
        matched = next(
            (names for names in keys if all(name in value for name in names)), None
        )
        if matched is None:
            raise WorkerBlocked(f"{field} is not a BrainGlobe ASR point.")
        point = np.asarray([value[name] for name in matched], dtype=np.float64)
    else:
        raise WorkerBlocked(f"{field} is not a BrainGlobe ASR point.")
    if point.shape != (3,) or not np.all(np.isfinite(point)):
        raise WorkerBlocked(f"{field} must contain three finite ASR micrometre values.")
    return point


def _planned_shank_candidates(handoff: dict[str, Any]) -> list[dict[str, Any]]:
    insertions = (
        handoff.get("insertionSnapshots")
        or handoff.get("insertion_snapshots")
        or handoff.get("insertions")
        or []
    )
    candidates: list[dict[str, Any]] = []
    for insertion_index, insertion in enumerate(insertions):
        if not isinstance(insertion, dict):
            continue
        insertion_id = str(
            insertion.get("insertionSnapshotId")
            or insertion.get("insertion_snapshot_id")
            or insertion.get("snapshotId")
            or insertion.get("planId")
            or f"insertion-{insertion_index + 1}"
        )
        plan_reference = (
            insertion.get("planRef")
            or insertion.get("plan_ref")
            or insertion.get("sourcePlan")
            or {}
        )
        shanks = (
            insertion.get("plannedShanks")
            or insertion.get("planned_shanks")
            or insertion.get("shanks")
            or []
        )
        for shank_index, shank in enumerate(shanks):
            if not isinstance(shank, dict):
                continue
            entry_value = (
                shank.get("surfaceEntry")
                or shank.get("surface_entry")
                or shank.get("entry")
            )
            tip_value = shank.get("tip") or shank.get("distalEnd")
            entry = _asr_point(
                entry_value, field=f"{insertion_id}.shanks[{shank_index}].entry"
            )
            tip = _asr_point(
                tip_value, field=f"{insertion_id}.shanks[{shank_index}].tip"
            )
            if float(np.linalg.norm(tip - entry)) <= 1e-9:
                raise WorkerBlocked(
                    f"{insertion_id}.shanks[{shank_index}] has zero length."
                )
            candidates.append(
                {
                    "candidateIndex": len(candidates),
                    "insertionSnapshotId": insertion_id,
                    "planId": str(
                        plan_reference.get("planId")
                        or plan_reference.get("plan_id")
                        or insertion.get("planId")
                        or insertion_id
                    ),
                    "planVersion": plan_reference.get("planVersion")
                    or plan_reference.get("plan_version")
                    or insertion.get("planVersion"),
                    "planInputSha256": plan_reference.get("planInputSha256")
                    or plan_reference.get("plan_input_sha256")
                    or insertion.get("planInputSha256"),
                    "shankId": str(
                        shank.get("shankId")
                        or shank.get("shank_id")
                        or f"shank-{shank_index}"
                    ),
                    "entry": entry,
                    "tip": tip,
                }
            )
    if len(candidates) > 128:
        raise WorkerBlocked(
            "Brain3D handoff contains more than 128 planned physical shanks."
        )
    return candidates


def _segment_distance(
    first_a: np.ndarray,
    first_b: np.ndarray,
    second_a: np.ndarray,
    second_b: np.ndarray,
) -> float:
    """Exact minimum distance between two finite 3-D segments."""
    u = first_b - first_a
    v = second_b - second_a
    w = first_a - second_a
    a = float(np.dot(u, u))
    b = float(np.dot(u, v))
    c = float(np.dot(v, v))
    d = float(np.dot(u, w))
    e = float(np.dot(v, w))
    denominator = a * c - b * b
    small = 1e-12
    if a <= small or c <= small:
        return float(
            min(
                np.linalg.norm(first_a - second_a),
                np.linalg.norm(first_a - second_b),
                np.linalg.norm(first_b - second_a),
                np.linalg.norm(first_b - second_b),
            )
        )
    s_numerator = 0.0
    s_denominator = denominator
    t_numerator = 0.0
    t_denominator = denominator
    if denominator < small:
        s_numerator = 0.0
        s_denominator = 1.0
        t_numerator = e
        t_denominator = c
    else:
        s_numerator = b * e - c * d
        t_numerator = a * e - b * d
        if s_numerator < 0.0:
            s_numerator = 0.0
            t_numerator = e
            t_denominator = c
        elif s_numerator > s_denominator:
            s_numerator = s_denominator
            t_numerator = e + b
            t_denominator = c
    if t_numerator < 0.0:
        t_numerator = 0.0
        if -d < 0.0:
            s_numerator = 0.0
        elif -d > a:
            s_numerator = s_denominator
        else:
            s_numerator = -d
            s_denominator = a
    elif t_numerator > t_denominator:
        t_numerator = t_denominator
        if -d + b < 0.0:
            s_numerator = 0.0
        elif -d + b > a:
            s_numerator = s_denominator
        else:
            s_numerator = -d + b
            s_denominator = a
    sc = 0.0 if abs(s_numerator) < small else s_numerator / s_denominator
    tc = 0.0 if abs(t_numerator) < small else t_numerator / t_denominator
    difference = w + sc * u - tc * v
    return float(np.linalg.norm(difference))


def _line_separation(
    first_origin: np.ndarray,
    first_axis: np.ndarray,
    second_origin: np.ndarray,
    second_axis: np.ndarray,
) -> float:
    cross = np.cross(first_axis, second_axis)
    norm = float(np.linalg.norm(cross))
    delta = second_origin - first_origin
    if norm <= 1e-12:
        return float(np.linalg.norm(np.cross(delta, first_axis)))
    return float(abs(np.dot(delta, cross)) / norm)


def _same_dv_metrics(
    observed_a: np.ndarray,
    observed_b: np.ndarray,
    planned_a: np.ndarray,
    planned_b: np.ndarray,
) -> dict[str, Any]:
    observed_direction = observed_b - observed_a
    planned_direction = planned_b - planned_a
    if (
        abs(float(observed_direction[1])) <= 1e-9
        or abs(float(planned_direction[1])) <= 1e-9
    ):
        return {"available": False, "reason": "near-horizontal DV projection"}
    lower = max(min(observed_a[1], observed_b[1]), min(planned_a[1], planned_b[1]))
    upper = min(max(observed_a[1], observed_b[1]), max(planned_a[1], planned_b[1]))
    if upper <= lower + 1e-9:
        return {"available": False, "reason": "no common finite DV support"}

    def point_at_dv(start: np.ndarray, direction: np.ndarray, dv: float) -> np.ndarray:
        return start + direction * ((dv - start[1]) / direction[1])

    observed_lower = point_at_dv(observed_a, observed_direction, lower)
    observed_upper = point_at_dv(observed_a, observed_direction, upper)
    planned_lower = point_at_dv(planned_a, planned_direction, lower)
    planned_upper = point_at_dv(planned_a, planned_direction, upper)
    error_lower = observed_lower - planned_lower
    error_upper = observed_upper - planned_upper

    def linear_rms(first: float, second: float) -> float:
        return math.sqrt(
            max(0.0, (first * first + first * second + second * second) / 3.0)
        )

    ap_rms = linear_rms(float(error_lower[0]), float(error_upper[0]))
    ml_rms = linear_rms(float(error_lower[2]), float(error_upper[2]))
    return {
        "available": True,
        "commonDVMinMicrometres": float(lower),
        "commonDVMaxMicrometres": float(upper),
        "apRMSMicrometres": ap_rms,
        "mlRMSMicrometres": ml_rms,
        "horizontalRMSMicrometres": math.hypot(ap_rms, ml_rms),
        "apAtCommonDVEndpointsMicrometres": [
            float(error_lower[0]),
            float(error_upper[0]),
        ],
        "mlAtCommonDVEndpointsMicrometres": [
            float(error_lower[2]),
            float(error_upper[2]),
        ],
    }


def track_shank_metrics(
    track: dict[str, Any], candidate: dict[str, Any]
) -> dict[str, Any]:
    observed_a = _asr_point(track.get("endpointA"), field="observed.endpointA")
    observed_b = _asr_point(track.get("endpointB"), field="observed.endpointB")
    planned_a = np.asarray(candidate["entry"], dtype=np.float64)
    planned_b = np.asarray(candidate["tip"], dtype=np.float64)
    observed_axis = _canonical_undirected_direction(observed_b - observed_a)
    planned_axis = (planned_b - planned_a) / np.linalg.norm(planned_b - planned_a)
    dot = float(np.clip(np.dot(observed_axis, planned_axis), -1.0, 1.0))
    aligned_observed = observed_axis if dot >= 0 else -observed_axis
    absolute_dot = float(np.clip(abs(dot), 0.0, 1.0))
    acute_angle = (
        0.0 if 1.0 - absolute_dot <= 1e-12 else math.degrees(math.acos(absolute_dot))
    )
    line_separation = _line_separation(
        observed_a, observed_axis, planned_a, planned_axis
    )
    observed_projection = sorted(
        [
            float(np.dot(observed_a - planned_a, planned_axis)),
            float(np.dot(observed_b - planned_a, planned_axis)),
        ]
    )
    planned_length = float(np.linalg.norm(planned_b - planned_a))
    axial_gap = max(
        0.0, -observed_projection[1], observed_projection[0] - planned_length
    )
    sagittal_delta = math.degrees(
        math.atan2(
            planned_axis[1] * aligned_observed[0]
            - planned_axis[0] * aligned_observed[1],
            planned_axis[1] * aligned_observed[1]
            + planned_axis[0] * aligned_observed[0],
        )
    )
    mediolateral_delta = math.degrees(
        math.atan2(
            planned_axis[1] * aligned_observed[2]
            - planned_axis[2] * aligned_observed[1],
            planned_axis[1] * aligned_observed[1]
            + planned_axis[2] * aligned_observed[2],
        )
    )
    finite_distance = _segment_distance(observed_a, observed_b, planned_a, planned_b)
    eligible = acute_angle <= 30.0 and line_separation <= 500.0 and axial_gap <= 1000.0
    review_cost = (
        (acute_angle / 20.0) ** 2
        + (line_separation / 250.0) ** 2
        + (axial_gap / 500.0) ** 2
    )
    return {
        "trackId": str(track.get("trackId")),
        "insertionSnapshotId": str(candidate["insertionSnapshotId"]),
        "planId": str(candidate["planId"]),
        "planVersion": candidate.get("planVersion"),
        "planInputSha256": candidate.get("planInputSha256"),
        "shankId": str(candidate["shankId"]),
        "axisAngleDegrees": acute_angle,
        "infiniteLineSeparationMicrometres": line_separation,
        "finiteSegmentDistanceMicrometres": finite_distance,
        "finiteAxialGapMicrometres": axial_gap,
        "sagittalProjectedTiltDeltaDegrees": sagittal_delta,
        "mediolateralProjectedTiltDeltaDegrees": mediolateral_delta,
        "sameDV": _same_dv_metrics(observed_a, observed_b, planned_a, planned_b),
        "reviewHeuristicCost": review_cost,
        "eligibleForSuggestion": eligible,
        "usableForNavigation": False,
    }


def _segment_box_parameter_interval(
    endpoint_a: np.ndarray,
    endpoint_b: np.ndarray,
    minimum: np.ndarray,
    maximum: np.ndarray,
) -> tuple[float, float] | None:
    """Clip a finite segment to one half-open ASR box using exact slab intervals."""

    direction = endpoint_b - endpoint_a
    lower = 0.0
    upper = 1.0
    for axis in range(3):
        delta = float(direction[axis])
        start = float(endpoint_a[axis])
        if abs(delta) <= 1e-15:
            if start < float(minimum[axis]) or start >= float(maximum[axis]):
                return None
            continue
        first = (float(minimum[axis]) - start) / delta
        second = (float(maximum[axis]) - start) / delta
        axis_lower = min(first, second)
        axis_upper = max(first, second)
        lower = max(lower, axis_lower)
        upper = min(upper, axis_upper)
        if upper <= lower:
            return None
    return (lower, upper) if upper > lower else None


def _merge_parameter_intervals(
    intervals: Iterable[tuple[float, float]],
) -> list[tuple[float, float]]:
    ordered = sorted(
        ((max(0.0, a), min(1.0, b)) for a, b in intervals if b > a),
        key=lambda item: (item[0], item[1]),
    )
    merged: list[tuple[float, float]] = []
    for lower, upper in ordered:
        if upper <= lower:
            continue
        if merged and lower <= merged[-1][1] + 1e-12:
            merged[-1] = (merged[-1][0], max(merged[-1][1], upper))
        else:
            merged.append((lower, upper))
    return merged


def _atlas_voxel_parameter_intervals(
    endpoint_a: np.ndarray,
    endpoint_b: np.ndarray,
    atlas: AtlasData,
) -> list[tuple[float, float, int]]:
    """Return exact constant-label intervals along a finite ASR segment."""

    annotation = atlas.require_annotation()
    resolution = np.asarray(atlas.resolution, dtype=np.float64)
    extent = np.asarray(annotation.shape, dtype=np.float64) * resolution
    clipped = _segment_box_parameter_interval(
        endpoint_a,
        endpoint_b,
        np.zeros(3, dtype=np.float64),
        extent,
    )
    if clipped is None:
        return []
    lower, upper = clipped
    direction = endpoint_b - endpoint_a
    boundaries = [lower, upper]
    for axis in range(3):
        delta = float(direction[axis])
        if abs(delta) <= 1e-15:
            continue
        for index in range(1, annotation.shape[axis]):
            parameter = (
                index * float(resolution[axis]) - float(endpoint_a[axis])
            ) / delta
            if lower < parameter < upper:
                boundaries.append(parameter)
    boundaries = sorted(set(round(value, 15) for value in boundaries))
    result: list[tuple[float, float, int]] = []
    for first, second in zip(boundaries, boundaries[1:]):
        if second <= first:
            continue
        midpoint = endpoint_a + direction * ((first + second) / 2.0)
        voxel = np.floor(midpoint / resolution).astype(np.int64)
        if np.any(voxel < 0) or np.any(voxel >= np.asarray(annotation.shape)):
            continue
        result.append((first, second, int(annotation[tuple(voxel)])))
    return result


def _structure_matches_roi(
    atlas: AtlasData,
    label_id: int,
    structure_id: int,
    include_descendants: bool,
) -> bool:
    if label_id == structure_id:
        return True
    if not include_descendants or label_id <= 0:
        return False
    try:
        entry = atlas.structures[label_id]
    except (KeyError, TypeError):
        return False
    return structure_id in [
        int(value) for value in (entry.get("structure_id_path") or [])
    ]


def _roi_member_definitions(roi_set: dict[str, Any]) -> list[dict[str, Any]]:
    structures = roi_set.get("allen_structures") or roi_set.get("allenStructures") or []
    boxes = roi_set.get("asr_boxes") or roi_set.get("asrBoxes") or []
    members: list[dict[str, Any]] = []
    for structure in structures:
        if not isinstance(structure, dict):
            continue
        structure_id = int(
            structure.get("structure_id") or structure.get("structureId")
        )
        descendants = bool(
            structure.get("include_descendants")
            if "include_descendants" in structure
            else structure.get("includeDescendants")
        )
        members.append(
            {
                "memberKey": f"allen:{structure_id}:{'descendants' if descendants else 'exact'}",
                "type": "allenStructure",
                "structureId": structure_id,
                "includeDescendants": descendants,
            }
        )
    for box in boxes:
        if not isinstance(box, dict):
            continue
        box_id = str(box.get("box_id") or box.get("boxId"))
        minimum = _asr_point(box.get("minimum"), field=f"ROI box {box_id} minimum")
        maximum = _asr_point(box.get("maximum"), field=f"ROI box {box_id} maximum")
        members.append(
            {
                "memberKey": f"box:{box_id}",
                "type": "asrBox",
                "boxId": box_id,
                "minimum": minimum,
                "maximum": maximum,
            }
        )
    return members


def _segment_roi_intervals(
    endpoint_a: np.ndarray,
    endpoint_b: np.ndarray,
    members: list[dict[str, Any]],
    atlas: AtlasData,
) -> dict[str, list[tuple[float, float]]]:
    voxel_intervals: list[tuple[float, float, int]] | None = None
    result: dict[str, list[tuple[float, float]]] = {}
    for member in members:
        intervals: list[tuple[float, float]] = []
        if member["type"] == "asrBox":
            clipped = _segment_box_parameter_interval(
                endpoint_a,
                endpoint_b,
                member["minimum"],
                member["maximum"],
            )
            if clipped is not None:
                intervals.append(clipped)
        else:
            if voxel_intervals is None:
                voxel_intervals = _atlas_voxel_parameter_intervals(
                    endpoint_a, endpoint_b, atlas
                )
            intervals.extend(
                (lower, upper)
                for lower, upper, label_id in voxel_intervals
                if _structure_matches_roi(
                    atlas,
                    label_id,
                    int(member["structureId"]),
                    bool(member["includeDescendants"]),
                )
            )
        result[str(member["memberKey"])] = _merge_parameter_intervals(intervals)
    return result


def _roi_side_summary(
    segments: list[dict[str, Any]],
    members: list[dict[str, Any]],
    atlas: AtlasData,
) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    traversed_members: set[str] = set()
    traversed_segments: set[str] = set()
    member_state = {
        str(member["memberKey"]): {"segmentIds": set(), "length": 0.0}
        for member in members
    }
    total_union_length = 0.0
    for segment in segments:
        endpoint_a = np.asarray(segment["endpointA"], dtype=np.float64)
        endpoint_b = np.asarray(segment["endpointB"], dtype=np.float64)
        segment_id = str(segment["segmentId"])
        length = float(np.linalg.norm(endpoint_b - endpoint_a))
        if not math.isfinite(length) or length <= 1e-12:
            continue
        member_intervals = _segment_roi_intervals(
            endpoint_a, endpoint_b, members, atlas
        )
        union_intervals = _merge_parameter_intervals(
            interval
            for intervals in member_intervals.values()
            for interval in intervals
        )
        if union_intervals:
            traversed_segments.add(segment_id)
            total_union_length += length * sum(
                upper - lower for lower, upper in union_intervals
            )
        for member_key, intervals in member_intervals.items():
            if not intervals:
                continue
            traversed_members.add(member_key)
            member_state[member_key]["segmentIds"].add(segment_id)
            member_state[member_key]["length"] += length * sum(
                upper - lower for lower, upper in intervals
            )
    summary = {
        "segmentIds": sorted(traversed_segments),
        "traversedMemberKeys": sorted(traversed_members),
        "totalTraversalLengthMicrometres": total_union_length,
    }
    return summary, member_state


def build_roi_summaries(
    handoff: dict[str, Any],
    tracks: list[dict[str, Any]],
    candidates: list[dict[str, Any]],
    dispositions: list[dict[str, Any]],
    atlas: AtlasData | None,
) -> list[dict[str, Any]]:
    if atlas is None:
        return []
    roi_sets = handoff.get("roi_sets") or handoff.get("roiSets") or []
    track_by_id = {str(track.get("trackId")): track for track in tracks}
    observed_insertions: dict[str, set[str]] = {}
    for disposition in dispositions:
        if not isinstance(disposition, dict):
            continue
        track_id = disposition.get("trackId")
        insertion_id = disposition.get("insertionSnapshotId")
        if isinstance(track_id, str) and isinstance(insertion_id, str):
            observed_insertions.setdefault(track_id, set()).add(insertion_id)
    summaries: list[dict[str, Any]] = []
    for roi_set in roi_sets:
        if not isinstance(roi_set, dict):
            continue
        members = _roi_member_definitions(roi_set)
        scope = str(roi_set.get("scope"))
        insertion_ids = {
            str(value)
            for value in (
                roi_set.get("insertion_snapshot_ids")
                or roi_set.get("insertionSnapshotIds")
                or (
                    [roi_set.get("insertion_snapshot_id")]
                    if roi_set.get("insertion_snapshot_id")
                    else []
                )
            )
        }
        planned_segments = [
            {
                "segmentId": f"{item['insertionSnapshotId']}::{item['shankId']}",
                "endpointA": item["entry"],
                "endpointB": item["tip"],
            }
            for item in candidates
            if scope == "global" or str(item["insertionSnapshotId"]) in insertion_ids
        ]
        observed_segments = [
            {
                "segmentId": track_id,
                "endpointA": track["endpointA"],
                "endpointB": track["endpointB"],
            }
            for track_id, track in track_by_id.items()
            if scope == "global"
            or bool(observed_insertions.get(track_id, set()) & insertion_ids)
        ]
        planned, planned_member_state = _roi_side_summary(
            planned_segments, members, atlas
        )
        observed, observed_member_state = _roi_side_summary(
            observed_segments, members, atlas
        )
        member_rows: list[dict[str, Any]] = []
        for member in members:
            member_key = str(member["memberKey"])
            definition = {
                key: value
                for key, value in member.items()
                if key not in {"minimum", "maximum"}
            }
            if member["type"] == "asrBox":
                definition["minimum"] = [float(value) for value in member["minimum"]]
                definition["maximum"] = [float(value) for value in member["maximum"]]
            member_rows.append(
                {
                    **definition,
                    "plannedSegmentIds": sorted(
                        planned_member_state[member_key]["segmentIds"]
                    ),
                    "observedTrackIds": sorted(
                        observed_member_state[member_key]["segmentIds"]
                    ),
                    "plannedTraversalLengthMicrometres": planned_member_state[
                        member_key
                    ]["length"],
                    "observedTraversalLengthMicrometres": observed_member_state[
                        member_key
                    ]["length"],
                }
            )
        planned_members = set(planned["traversedMemberKeys"])
        observed_members = set(observed["traversedMemberKeys"])
        summaries.append(
            {
                "roiSetId": str(roi_set.get("roi_set_id") or roi_set.get("roiSetId")),
                "name": str(roi_set.get("name")),
                "scope": scope,
                "insertionSnapshotIds": sorted(insertion_ids),
                "members": member_rows,
                "planned": planned,
                "observed": observed,
                "intersection": {
                    "traversedMemberKeys": sorted(planned_members & observed_members),
                },
                "union": {
                    "traversedMemberKeys": sorted(planned_members | observed_members),
                },
                "aggregation": "per-segment interval union; overlapping parent/child and box membership is not double-counted",
                "usableForNavigation": False,
            }
        )
    return summaries


def _validated_brain3d_review_dispositions(
    context: dict[str, Any],
    tracks: list[dict[str, Any]],
    candidates: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    raw_dispositions = context.get("reviewDispositions")
    if not isinstance(raw_dispositions, list):
        raise WorkerBlocked("Brain3D review dispositions must be an array.")
    try:
        dispositions = [
            Brain3DReviewDispositionContract.model_validate(item)
            for item in raw_dispositions
        ]
    except ValidationError as error:
        raise WorkerBlocked(
            "Brain3D review dispositions failed strict validation; every decision requires a reviewer, reason, and timestamp."
        ) from error

    disposition_ids = [item.id for item in dispositions]
    if len(disposition_ids) != len(set(disposition_ids)):
        raise WorkerBlocked("Brain3D review disposition IDs must be unique.")
    if any(
        item.reviewerLabel != item.reviewerLabel.strip()
        or item.reason != item.reason.strip()
        or item.confirmedAt.tzinfo is None
        or item.confirmedAt.utcoffset() is None
        for item in dispositions
    ):
        raise WorkerBlocked(
            "Brain3D review labels and reasons must be trimmed and confirmation times must include a timezone."
        )

    track_ids = [str(track.get("trackId")) for track in tracks]
    if len(track_ids) != len(set(track_ids)) or any(
        value == "None" for value in track_ids
    ):
        raise WorkerBlocked("Blind reconstructed track IDs must be present and unique.")
    expected_tracks = set(track_ids)
    candidate_keys = {
        (str(item["insertionSnapshotId"]), str(item["shankId"])) for item in candidates
    }
    insertion_ids = {key[0] for key in candidate_keys}
    observed_covered: set[str] = set()
    exact_claims: set[tuple[str, str]] = set()
    ambiguous_insertions: set[str] = set()
    missing_claims: set[tuple[str, str]] = set()

    def claim_observed(track_id: str | None) -> str:
        if track_id is None or track_id not in expected_tracks:
            raise WorkerBlocked(
                "A Brain3D disposition references an unknown observed track."
            )
        if track_id in observed_covered:
            raise WorkerBlocked(
                "Each observed track must have exactly one manual disposition."
            )
        observed_covered.add(track_id)
        return track_id

    for item in dispositions:
        insertion_id = item.insertionSnapshotId
        shank_id = item.shankId
        if item.state == "exactShank":
            claim_observed(item.trackId)
            if insertion_id is None or shank_id is None:
                raise WorkerBlocked(
                    "An exact-shank disposition requires insertion and shank IDs."
                )
            key = (insertion_id, shank_id)
            if key not in candidate_keys:
                raise WorkerBlocked(
                    "An exact-shank disposition references an unknown planned shank."
                )
            if key in exact_claims:
                raise WorkerBlocked(
                    "A planned physical shank cannot be exactly assigned twice."
                )
            exact_claims.add(key)
        elif item.state == "insertionLevelAmbiguous":
            claim_observed(item.trackId)
            if insertion_id not in insertion_ids or shank_id is not None:
                raise WorkerBlocked(
                    "An insertion-level ambiguous disposition requires a known insertion and no shank ID."
                )
            ambiguous_insertions.add(str(insertion_id))
        elif item.state == "observedUnmatched":
            claim_observed(item.trackId)
            if insertion_id is not None or shank_id is not None:
                raise WorkerBlocked(
                    "An observed-unmatched disposition cannot reference a planned insertion or shank."
                )
        else:
            if item.trackId is not None or insertion_id is None or shank_id is None:
                raise WorkerBlocked(
                    "A planned-not-observed disposition requires one planned shank and no observed track."
                )
            key = (insertion_id, shank_id)
            if key not in candidate_keys:
                raise WorkerBlocked(
                    "A planned-not-observed disposition references an unknown planned shank."
                )
            if key in missing_claims:
                raise WorkerBlocked(
                    "A planned physical shank cannot be marked missing twice."
                )
            missing_claims.add(key)

    missing_tracks = sorted(expected_tracks - observed_covered)
    if missing_tracks:
        raise WorkerBlocked(
            f"Manual Brain3D review is incomplete for {len(missing_tracks)} observed track(s)."
        )
    if exact_claims & missing_claims:
        raise WorkerBlocked(
            "A planned physical shank cannot be both exactly observed and planned-not-observed."
        )
    if any(key[0] in ambiguous_insertions for key in missing_claims):
        raise WorkerBlocked(
            "A shank in an insertion-level ambiguous match cannot also be marked planned-not-observed."
        )
    planned_covered = (
        exact_claims
        | missing_claims
        | {key for key in candidate_keys if key[0] in ambiguous_insertions}
    )
    missing_planned = candidate_keys - planned_covered
    if missing_planned:
        raise WorkerBlocked(
            f"Manual Brain3D review is incomplete for {len(missing_planned)} planned physical shank(s)."
        )
    return raw_dispositions


def build_brain3d_review(
    project: dict[str, Any],
    tracks_document: dict[str, Any],
    *,
    require_complete: bool = True,
    atlas: AtlasData | None = None,
) -> dict[str, Any]:
    context = project.get("brain3dContext")
    if not isinstance(context, dict):
        return {
            "schemaVersion": 1,
            "status": "noBrain3DPrior",
            "policy": "brain3d-prior-posthoc-overlay-only-v1",
            "matrix": [],
            "suggestions": [],
            "reviewDispositions": [],
            "usableForNavigation": False,
        }
    if context.get("blindReviewLocked") is not True:
        raise WorkerBlocked(
            "Brain3D context cannot be reviewed or exported until blind registration and track review are locked."
        )
    handoff = context.get("handoff")
    if not isinstance(handoff, dict):
        raise WorkerBlocked(
            "Brain3D context is missing its immutable handoff snapshot."
        )
    candidates = _planned_shank_candidates(handoff)
    tracks = tracks_document.get("tracks") or []
    matrix = [
        track_shank_metrics(track, candidate)
        for track in tracks
        for candidate in candidates
    ]
    metric_by_pair = {
        (
            str(item["trackId"]),
            str(item["insertionSnapshotId"]),
            str(item["shankId"]),
        ): item
        for item in matrix
    }
    track_ids = [str(track.get("trackId")) for track in tracks]
    size = len(track_ids) + len(candidates)
    suggestions: list[dict[str, Any]] = []
    if track_ids and candidates:
        large = 1_000_000.0
        costs = np.full((size, size), large, dtype=np.float64)
        for track_index, track_id in enumerate(track_ids):
            for candidate_index, candidate in enumerate(candidates):
                metric = metric_by_pair[
                    (
                        track_id,
                        str(candidate["insertionSnapshotId"]),
                        str(candidate["shankId"]),
                    )
                ]
                if metric["eligibleForSuggestion"]:
                    costs[track_index, candidate_index] = float(
                        metric["reviewHeuristicCost"]
                    )
            costs[track_index, len(candidates) + track_index] = 4.0
        for candidate_index in range(len(candidates)):
            costs[len(track_ids) + candidate_index, candidate_index] = 4.0
        costs[len(track_ids) :, len(candidates) :] = 0.0
        rows, columns = optimize.linear_sum_assignment(costs)
        for row, column in zip(rows.tolist(), columns.tolist(), strict=True):
            if (
                row >= len(track_ids)
                or column >= len(candidates)
                or costs[row, column] >= large
            ):
                continue
            track_id = track_ids[row]
            candidate = candidates[column]
            metric = metric_by_pair[
                (
                    track_id,
                    str(candidate["insertionSnapshotId"]),
                    str(candidate["shankId"]),
                )
            ]
            if not metric["eligibleForSuggestion"]:
                continue
            alternatives = sorted(
                (
                    item
                    for item in matrix
                    if item["trackId"] == track_id and item["eligibleForSuggestion"]
                ),
                key=lambda item: (
                    float(item["reviewHeuristicCost"]),
                    str(item["insertionSnapshotId"]),
                    str(item["shankId"]),
                ),
            )
            near_tie = len(alternatives) > 1 and (
                float(alternatives[1]["reviewHeuristicCost"])
                - float(alternatives[0]["reviewHeuristicCost"])
                < 0.5
            )
            same_insertion = [
                item
                for item in candidates
                if item["insertionSnapshotId"] == candidate["insertionSnapshotId"]
                and item["shankId"] != candidate["shankId"]
            ]
            rmse = float(
                next(track for track in tracks if track["trackId"] == track_id).get(
                    "rmseMicrometres", 0.0
                )
            )
            close_shank = any(
                _segment_distance(
                    candidate["entry"], candidate["tip"], other["entry"], other["tip"]
                )
                < 2.0 * max(100.0, rmse)
                for other in same_insertion
            )
            suggestions.append(
                {
                    "trackId": track_id,
                    "insertionSnapshotId": candidate["insertionSnapshotId"],
                    "shankId": None
                    if near_tie or close_shank
                    else candidate["shankId"],
                    "state": "insertionLevelAmbiguous"
                    if near_tie or close_shank
                    else "exactShankSuggested",
                    "reviewHeuristicCost": metric["reviewHeuristicCost"],
                    "requiresReviewerConfirmation": True,
                }
            )
    review_dispositions = context.get("reviewDispositions") or []
    if require_complete:
        review_dispositions = _validated_brain3d_review_dispositions(
            context,
            tracks,
            candidates,
        )
    review = {
        "schemaVersion": 1,
        "status": "reviewed" if require_complete else "suggestionsOnly",
        "policy": "brain3d-prior-posthoc-overlay-only-v1",
        "priorReceipt": context.get("priorReceipt"),
        "subjectBinding": context.get("subjectBinding"),
        "reviewHeuristic": {
            "angleScaleDegrees": 20.0,
            "lineSeparationScaleMicrometres": 250.0,
            "axialGapScaleMicrometres": 500.0,
            "maximumAngleDegrees": 30.0,
            "maximumLineSeparationMicrometres": 500.0,
            "maximumAxialGapMicrometres": 1000.0,
            "unmatchedCost": 4.0,
            "scientificAcceptanceThreshold": False,
        },
        "matrix": matrix,
        "suggestions": suggestions,
        "reviewDispositions": review_dispositions,
        "roiSummaries": build_roi_summaries(
            handoff,
            tracks,
            candidates,
            review_dispositions,
            atlas,
        ),
        "usableForNavigation": False,
    }
    review["reviewSha256"] = canonical_json_sha256(review)
    return review


def atlas_ontology_payload(atlas: AtlasData) -> dict[str, Any]:
    structures: list[dict[str, Any]] = []
    try:
        structure_ids = sorted(int(value) for value in atlas.structures.keys())
    except AttributeError:
        structure_ids = []
    for structure_id in structure_ids:
        entry = atlas.structures[structure_id]
        path = [int(value) for value in (entry.get("structure_id_path") or [])]
        rgb = entry.get("rgb_triplet") or entry.get("rgb") or [170, 170, 170]
        structures.append(
            {
                "id": structure_id,
                "acronym": str(entry.get("acronym", structure_id)),
                "name": str(entry.get("name", "Unknown")),
                "structureIDPath": path,
                "parentStructureID": path[-2] if len(path) >= 2 else None,
                "rgbTriplet": [int(value) for value in rgb],
            }
        )
    return {
        "schemaVersion": 1,
        "atlas": atlas.name,
        "atlasVersion": atlas.version,
        "orientation": atlas.orientation,
        "resolutionMicrons": list(atlas.resolution),
        "structures": structures,
    }


def _blind_track_review_preview(tracks_document: dict[str, Any]) -> dict[str, Any]:
    """Return the compact native-app DTO for editing one complete partition."""

    tracks = tracks_document.get("tracks")
    unassigned = tracks_document.get("unassignedSourcePointIDs")
    if not isinstance(tracks, list) or not isinstance(unassigned, list):
        raise WorkerBlocked(
            "Blind reconstruction did not produce a reviewable track document."
        )
    preview_tracks = [
        {
            "groupId": str(track.get("groupId")),
            "trackId": str(track.get("trackId")),
            "fitDigest": str(track.get("fitDigest")),
            "sourcePointIDs": list(track.get("sourcePointIDs") or []),
            "pointCount": int(track.get("pointCount", 0)),
            "distinctSliceCount": int(track.get("distinctSliceCount", 0)),
            "rmseMicrometres": float(track.get("rmseMicrometres", 0.0)),
            "supportLengthMicrometres": float(
                track.get("supportLengthMicrometres", 0.0)
            ),
            "usableForNavigation": False,
        }
        for track in tracks
        if isinstance(track, dict)
    ]
    preview_tracks.sort(key=lambda item: (item["groupId"], item["trackId"]))
    preview = {
        "schemaVersion": BLIND_TRACK_REVIEW_SCHEMA_VERSION,
        "reviewedTrackSetSha256": tracks_document.get("reviewedTrackSetSha256"),
        "reviewStateSha256": tracks_document.get("reviewStateSha256"),
        "tracks": preview_tracks,
        "unassignedSourcePointIDs": sorted(str(value) for value in unassigned),
        "usableForNavigation": False,
    }
    if not all(
        isinstance(preview[field], str)
        and bool(re.fullmatch(r"[0-9a-f]{64}", preview[field]))
        for field in ("reviewedTrackSetSha256", "reviewStateSha256")
    ):
        raise WorkerBlocked("Blind reconstruction returned invalid review digests.")
    return preview


def command_review_blind_tracks(args: argparse.Namespace) -> dict[str, Any]:
    """Build an editable pre-lock 3-D track partition without plan/ROI context."""

    project = read_json(args.project)
    blockers = project_blockers(project)
    if blockers:
        raise WorkerBlocked(" ".join(blockers))
    if project.get("blindReviewLocked") is True:
        raise WorkerBlocked(
            "Blind track review is locked; unlock it before changing or rebuilding the partition."
        )
    args.out.mkdir(parents=True, exist_ok=True)
    atlas = load_atlas(project, annotations=True)
    tracks_relative, _ = reconstruct_probe_tracks(project, atlas, args.out)
    tracks_document = read_json(args.out / tracks_relative)
    preview = _blind_track_review_preview(tracks_document)
    preview_path = args.out / "blind-track-review-preview.json"
    write_json(preview_path, preview)
    return result_envelope(
        "review-blind-tracks",
        "ok",
        project,
        preview_path,
        [
            f"Prepared {len(preview['tracks'])} blind finite track group(s).",
            "The partition is retrospective evidence only and is not usable for navigation.",
        ],
        blind_track_review_preview=preview,
    )


def command_review_brain3d(args: argparse.Namespace) -> dict[str, Any]:
    """Reconstruct blind tracks first, then reveal a post-lock matching preview."""

    project = read_json(args.project)
    blockers = project_blockers(project)
    if blockers:
        raise WorkerBlocked(" ".join(blockers))
    context = project.get("brain3dContext")
    if not isinstance(context, dict):
        raise WorkerBlocked(
            "Load one immutable Brain3D handoff before building match review."
        )
    if context.get("blindReviewLocked") is not True:
        raise WorkerBlocked(
            "Lock blind registration and track review before revealing Brain3D matching context."
        )
    args.out.mkdir(parents=True, exist_ok=True)
    atlas = load_atlas(project, annotations=True)
    _verified_locked_atlas_identity_hashes(project, atlas)
    tracks_relative, _ = reconstruct_probe_tracks(project, atlas, args.out)
    tracks_document = read_json(args.out / tracks_relative)
    review = build_brain3d_review(
        project,
        tracks_document,
        require_complete=False,
        atlas=atlas,
    )
    handoff = context.get("handoff")
    if not isinstance(handoff, dict):
        raise WorkerBlocked(
            "Brain3D context is missing its immutable handoff snapshot."
        )
    planned = _planned_shank_candidates(handoff)
    preview = {
        "schemaVersion": 1,
        "reviewedTrackSetSha256": tracks_document.get("reviewedTrackSetSha256"),
        "tracks": [
            {
                key: track.get(key)
                for key in (
                    "trackId",
                    "fitDigest",
                    "endpointA",
                    "endpointB",
                    "supportLengthMicrometres",
                    "rmseMicrometres",
                    "pointCount",
                    "distinctSliceCount",
                    "leaveOneSectionOutSensitivity",
                    "usableForNavigation",
                )
            }
            for track in tracks_document.get("tracks", [])
        ],
        "plannedShanks": [
            {
                "insertionSnapshotId": str(item["insertionSnapshotId"]),
                "planId": str(item["planId"]),
                "shankId": str(item["shankId"]),
                "entry": [float(value) for value in item["entry"]],
                "tip": [float(value) for value in item["tip"]],
                "usableForNavigation": False,
            }
            for item in planned
        ],
        "suggestions": review["suggestions"],
        "matrix": review["matrix"],
        "roiSummaries": review["roiSummaries"],
        "unassignedSourcePointIDs": tracks_document.get("unassignedSourcePointIDs", []),
        "usableForNavigation": False,
    }
    preview_path = args.out / "brain3d-review-preview.json"
    write_json(preview_path, preview)
    return result_envelope(
        "review-brain3d",
        "ok",
        project,
        preview_path,
        [
            f"Prepared post-lock review for {len(preview['tracks'])} observed track(s) and {len(planned)} planned physical shank(s).",
            "Suggestions are rankings only; every observed track and planned shank still requires manual disposition.",
        ],
        brain3d_review_preview=preview,
    )


def atlas_provenance_hashes(
    project: dict[str, Any], atlas: AtlasData, ontology_path: Path
) -> dict[str, str]:
    hashes: dict[str, str] = {}
    candidates = {
        "referenceVolume": atlas.root_dir / "reference.tiff",
        "annotationVolume": atlas.root_dir / "annotation.tiff",
        "atlasMetadata": atlas.root_dir / "metadata.json",
        "sourceOntology": atlas.root_dir / "structures.json",
    }
    fixture_value = (project.get("atlasAssets") or {}).get("fixturePath")
    if fixture_value:
        candidates["fixtureArchive"] = Path(str(fixture_value))
    for name, path in candidates.items():
        digest = hash_file(path)
        if digest:
            hashes[name] = digest
    ontology_digest = hash_file(ontology_path)
    if ontology_digest:
        hashes["exportedOntology"] = ontology_digest
    hashes.update(_verified_locked_atlas_identity_hashes(project, atlas))
    return hashes


def _verified_locked_atlas_identity_hashes(
    project: dict[str, Any], atlas: AtlasData
) -> dict[str, str]:
    context = project.get("brain3dContext")
    if not isinstance(context, dict):
        return {}
    handoff = context.get("handoff")
    handoff_atlas = handoff.get("atlas") if isinstance(handoff, dict) else None
    if not isinstance(handoff_atlas, dict):
        raise WorkerBlocked(
            "The selected Brain3D handoff lacks its exact atlas snapshot."
        )
    expected_identities = {
        "atlasMetadata": handoff_atlas.get("atlas_metadata_sha256"),
        "annotationArrayIdentity": handoff_atlas.get("annotation_sha256"),
        "ontologyIdentity": handoff_atlas.get("ontology_sha256"),
    }
    missing = [name for name, value in expected_identities.items() if not value]
    if missing:
        raise WorkerBlocked(
            "The selected Brain3D handoff lacks exact atlas identities: "
            + ", ".join(sorted(missing))
        )
    actual_identities: dict[str, str | None] = {
        "atlasMetadata": hash_file(atlas.root_dir / "metadata.json"),
        "annotationArrayIdentity": _annotation_array_identity_sha256(atlas),
        "ontologyIdentity": _brain3d_ontology_identity_sha256(atlas),
    }
    unavailable = [name for name, value in actual_identities.items() if value is None]
    if unavailable:
        raise WorkerBlocked(
            "The installed atlas lacks exact assets required by the Brain3D handoff: "
            + ", ".join(sorted(unavailable))
        )
    mismatched = [
        name
        for name, actual in actual_identities.items()
        if actual != expected_identities[name]
    ]
    if mismatched:
        raise WorkerBlocked(
            "The installed atlas does not exactly match the locked Brain3D handoff: "
            + ", ".join(sorted(mismatched))
            + ". Atlas identity mismatches cannot be overridden."
        )
    return {name: str(value) for name, value in actual_identities.items()}


def _annotation_array_identity_sha256(atlas: AtlasData) -> str:
    annotation = atlas.require_annotation()
    if not isinstance(annotation, np.ndarray) or annotation.ndim != 3:
        raise WorkerBlocked("The installed atlas annotation is not one 3-D array.")
    digest = hashlib.sha256()
    if annotation.flags.c_contiguous:
        digest.update(memoryview(annotation).cast("B"))
    else:
        for slab in annotation:
            digest.update(memoryview(np.ascontiguousarray(slab)).cast("B"))
    return digest.hexdigest()


def _brain3d_ontology_identity_sha256(atlas: AtlasData) -> str:
    try:
        structure_ids = sorted(int(value) for value in atlas.structures.keys())
    except (AttributeError, TypeError, ValueError) as error:
        raise WorkerBlocked(
            "The installed atlas ontology cannot be normalized."
        ) from error
    normalized: list[dict[str, Any]] = []
    for structure_id in structure_ids:
        entry = atlas.structures[structure_id]
        path = entry.get("structure_id_path") or []
        rgb = entry.get("rgb_triplet") or entry.get("rgb") or [170, 170, 170]
        normalized.append(
            {
                "structureId": structure_id,
                "acronym": str(entry.get("acronym", structure_id)),
                "name": str(entry.get("name", "Unknown")),
                "structureIdPath": [int(value) for value in path],
                "rgb": [int(value) for value in rgb],
            }
        )
    encoded = json.dumps(
        normalized,
        allow_nan=False,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def source_suffix(path: Path, default: str) -> str:
    suffix = "".join(path.suffixes)
    return suffix if suffix else default


def command_export_atlas(args: argparse.Namespace) -> dict[str, Any]:
    project = read_json(args.project)
    blockers = project_blockers(project)
    if blockers:
        raise WorkerBlocked(" ".join(blockers))
    args.out.mkdir(parents=True, exist_ok=True)
    atlas = load_atlas(project, annotations=True)
    source_hashes: dict[str, str] = {}
    input_file_hashes: dict[str, str] = {}
    slice_exports: list[dict[str, Any]] = []
    export_parameter_files: list[str] = []
    portable_project = json.loads(json.dumps(project))
    portable_slices = {
        str(item.get("id")): item for item in portable_project.get("slices", [])
    }
    for slice_record in project.get("slices", []):
        artifact_errors = validate_registration_artifacts(slice_record, atlas)
        if artifact_errors:
            raise WorkerBlocked(
                "Invalid accepted registration artifacts: " + "; ".join(artifact_errors)
            )
        record_id = str(slice_record.get("id"))
        slice_id = safe_name(record_id)
        slice_dir = args.out / "slices" / slice_id
        slice_dir.mkdir(parents=True, exist_ok=True)
        artifacts = artifact_record(slice_record)
        copied_sources: dict[Path, str] = {}

        def copy_semantic_file(
            value: Any,
            stem: str,
            *,
            default_suffix: str = ".bin",
            required: bool = False,
        ) -> str | None:
            if not value:
                if required:
                    raise WorkerBlocked(
                        f"Accepted slice {record_id} is missing required {stem} input."
                    )
                return None
            source = Path(str(value)).expanduser()
            if not source.is_file():
                if required:
                    raise WorkerBlocked(
                        f"Accepted slice {record_id} is missing required file: {source}"
                    )
                return None
            resolved = source.resolve()
            input_digest = hash_file(source)
            if input_digest:
                input_file_hashes[f"{record_id}:{stem}"] = input_digest
            if resolved in copied_sources:
                return copied_sources[resolved]
            destination = slice_dir / f"{stem}{source_suffix(source, default_suffix)}"
            relative = copy_export_file(source, destination, args.out)
            copied_sources[resolved] = relative
            return relative

        source_path = copy_semantic_file(
            slice_record.get("sourceImagePath"), "source-image", required=True
        )
        portable_slice = portable_slices[record_id]
        portable_slice["sourceImagePath"] = source_path

        artifact_names = (
            ("preparedImagePath", "prepared-image", ".png"),
            ("structuralImagePath", "structural-channel", ".png"),
            ("probeChannelImagePath", "probe-channel", ".png"),
            ("sourceOverlayImagePath", "source-overlay", ".png"),
            ("tissueMaskPath", "tissue-mask", ".png"),
            ("selectionMaskPath", "selection-mask", ".png"),
            ("rawSelectionMaskPath", "raw-selection-mask", ".png"),
            ("atlasReferencePath", "atlas-reference", ".png"),
            ("registeredImagePath", "registered-section", ".png"),
            ("overlayImagePath", "atlas-overlay", ".png"),
            ("boundaryImagePath", "atlas-boundaries", ".png"),
            ("checkerboardImagePath", "checkerboard", ".png"),
            ("differenceImagePath", "difference", ".png"),
            ("annotationImagePath", "annotation-ids", ".tif"),
            ("trackMaskPath", "probe-track-mask", ".png"),
            ("trackOverlayPath", "probe-track-overlay", ".png"),
        )
        exported_artifacts: dict[str, Any] = {}
        for key, stem, default_suffix in artifact_names:
            relative = copy_semantic_file(
                artifacts.get(key),
                stem,
                default_suffix=default_suffix,
                required=key in {"boundaryImagePath", "annotationImagePath"},
            )
            exported_artifacts[key] = relative
        annotation_relative = exported_artifacts["annotationImagePath"]
        boundary_relative = exported_artifacts["boundaryImagePath"]

        chain = json.loads(json.dumps(slice_record.get("transformChain", {})))
        usable_affines = [
            item
            for item in chain.get("transforms", [])
            if item.get("kind") == "affine" and item.get("transformParametersPath")
        ]
        if not usable_affines:
            raise WorkerBlocked(
                f"Accepted slice {slice_record.get('id')} has no affine parameter file."
            )
        affine_source = Path(str(usable_affines[-1]["transformParametersPath"]))
        affine_path = slice_dir / "atlas-to-slice-affine.tfm"
        affine_relative = copy_export_file(affine_source, affine_path, args.out)
        usable_affines[-1]["transformParametersPath"] = affine_relative
        export_parameter_files.append(affine_relative)
        affine_digest = hash_file(affine_source)
        if affine_digest:
            input_file_hashes[f"{record_id}:atlas-to-slice-affine"] = affine_digest
        transform_path = slice_dir / "transform-chain.json"
        write_json(transform_path, chain)
        transform_relative = relative_export_path(args.out, transform_path)

        portable_chain = portable_slice.setdefault("transformChain", {})
        portable_chain["direction"] = chain.get("direction", "atlasToSlice")
        portable_chain["transforms"] = chain.get("transforms", [])
        exported_artifacts["transformPath"] = affine_relative
        if "atlasAPIndex" in artifacts:
            exported_artifacts["atlasAPIndex"] = artifacts.get("atlasAPIndex")
        portable_slice["artifacts"] = exported_artifacts

        review_artifacts: dict[str, str] = {}
        for key in (
            "atlasReferencePath",
            "registeredImagePath",
            "overlayImagePath",
            "checkerboardImagePath",
            "differenceImagePath",
            "trackOverlayPath",
        ):
            if exported_artifacts.get(key):
                review_artifacts[key] = str(exported_artifacts[key])
        digest = hash_file(Path(slice_record.get("sourceImagePath", "")))
        if digest:
            source_hashes[record_id] = digest
        slice_exports.append(
            {
                "id": slice_record.get("id"),
                "sourceImagePath": source_path,
                "sourceArtifacts": exported_artifacts,
                "atlasCoordinateImagePath": annotation_relative,
                "regionOutlinesPath": boundary_relative,
                "transformChainPath": transform_relative,
                "qc": slice_record.get("qc", {}),
                "probeTrack": slice_record.get("probeTrack"),
                "reviewArtifacts": review_artifacts,
            }
        )

    provenance_dir = args.out / "provenance"
    provenance_dir.mkdir(parents=True, exist_ok=True)
    deep_slice_value = portable_project.get("provenance", {}).get(
        "deepSlicePredictionsPath"
    )
    if deep_slice_value and Path(str(deep_slice_value)).is_file():
        predictions_path = provenance_dir / "deepslice-predictions.csv"
        predictions_relative = copy_export_file(
            Path(str(deep_slice_value)), predictions_path, args.out
        )
        portable_project["provenance"]["deepSlicePredictionsPath"] = (
            predictions_relative
        )
        digest = hash_file(Path(str(deep_slice_value)))
        if digest:
            input_file_hashes["project:deepslice-predictions"] = digest
    else:
        portable_project.get("provenance", {}).pop("deepSlicePredictionsPath", None)

    atlas_dir = args.out / "atlas"
    ontology_path = atlas_dir / "structures.json"
    write_json(ontology_path, atlas_ontology_payload(atlas))
    ontology_relative = relative_export_path(args.out, ontology_path)
    atlas_hashes = atlas_provenance_hashes(project, atlas, ontology_path)
    atlas_checksum = combined_checksum(atlas_hashes)

    portable_project["datasetRootPath"] = "."
    portable_project["atlasAssets"] = {
        "atlasName": atlas.name,
        "atlasVersion": atlas.version,
        "orientation": atlas.orientation,
        "resolutionMicrons": list(atlas.resolution),
        "ontologyPath": ontology_relative,
        "atlasChecksum": atlas_checksum,
    }
    accepted_project_path = args.out / "accepted-project.json"
    write_json(accepted_project_path, portable_project)
    accepted_project_relative = relative_export_path(args.out, accepted_project_path)

    legacy_track_path, _legacy_sites_path = reconstruct_probe_track(
        project, atlas, args.out
    )
    tracks_path, sites_path = reconstruct_probe_tracks(project, atlas, args.out)
    tracks_document = json.loads((args.out / tracks_path).read_text(encoding="utf-8"))
    brain3d_review = build_brain3d_review(project, tracks_document, atlas=atlas)
    brain3d_review_path = args.out / "brain3d-review.json"
    write_json(brain3d_review_path, brain3d_review)
    brain3d_review_relative = relative_export_path(args.out, brain3d_review_path)
    payload_paths = {accepted_project_relative, ontology_relative}
    for slice_export in slice_exports:
        for key in (
            "sourceImagePath",
            "atlasCoordinateImagePath",
            "regionOutlinesPath",
            "transformChainPath",
        ):
            if slice_export.get(key):
                payload_paths.add(str(slice_export[key]))
        payload_paths.update(
            str(value)
            for value in slice_export.get("sourceArtifacts", {}).values()
            if isinstance(value, str)
        )
    predictions_relative = portable_project.get("provenance", {}).get(
        "deepSlicePredictionsPath"
    )
    if predictions_relative:
        payload_paths.add(str(predictions_relative))
    payload_paths.add(tracks_path)
    payload_paths.add(brain3d_review_relative)
    if legacy_track_path:
        payload_paths.add(legacy_track_path)
    if sites_path:
        payload_paths.add(sites_path)
    payload_paths.update(export_parameter_files)
    export_file_hashes: dict[str, str] = {}
    for relative in sorted(payload_paths):
        artifact_path = args.out / relative
        digest = hash_file(artifact_path)
        if digest:
            export_file_hashes[relative] = digest
    blind_slice_candidates = [
        {
            "sliceID": slice_record.get("id"),
            "probeTrackCandidates": slice_record.get("probeTrackCandidates")
            if isinstance(slice_record.get("probeTrackCandidates"), list)
            else (
                [slice_record.get("probeTrack")]
                if slice_record.get("probeTrack")
                else []
            ),
        }
        for slice_record in project.get("slices", [])
    ]
    affine_records = [
        {
            "sliceID": slice_record.get("id"),
            "transforms": [
                transform_record
                for transform_record in (slice_record.get("transformChain") or {}).get(
                    "transforms", []
                )
                if transform_record.get("kind") == "affine"
            ],
        }
        for slice_record in project.get("slices", [])
    ]
    deep_slice_outputs = {
        key: value
        for key, value in (project.get("provenance") or {}).items()
        if str(key).startswith("deepSlice") or key == "poseEngine"
    }
    blind_outputs = {
        "runId": canonical_json_sha256(
            {
                "projectID": project.get("id"),
                "tracks": tracks_document.get("reviewedTrackSetSha256"),
                "workerVersion": WORKER_VERSION,
            }
        )[:32],
        "policy": "brain3d-prior-posthoc-overlay-only-v1",
        "registrationInputSha256": blind_registration_input_sha256(project),
        "deepSliceOutputSha256": canonical_json_sha256(deep_slice_outputs),
        "affineOutputSha256": canonical_json_sha256(affine_records),
        "trackCandidateOutputSha256": canonical_json_sha256(blind_slice_candidates),
        "reviewedTrackSetSha256": tracks_document.get("reviewedTrackSetSha256"),
    }
    export = {
        "schemaVersion": ATLAS_EXPORT_SCHEMA_VERSION,
        "projectID": project.get("id"),
        "atlas": project.get("atlas"),
        "exportedAt": utc_now(),
        "outputFolderPath": ".",
        "acceptedProjectPath": accepted_project_relative,
        "atlasOntologyPath": ontology_relative,
        "sliceExports": slice_exports,
        "probeTrackPath": legacy_track_path,
        "probeTracksPath": tracks_path,
        "brain3dReviewPath": brain3d_review_relative,
        "siteAssignmentsPath": sites_path,
        "priorReceipt": brain3d_review.get("priorReceipt"),
        "colonySubjectReceipt": project.get("colonySubjectReceipt"),
        "blindOutputs": blind_outputs,
        "provenance": {
            "appVersion": "0.2",
            "atlasChecksum": atlas_checksum,
            "atlasFileHashes": atlas_hashes,
            "engineVersions": {
                "BrainGlobeAtlas": atlas.version,
                "DeepSlice": DEEPSLICE_VERSION,
                "SimpleITK": sitk.Version_VersionString(),
                "worker": WORKER_VERSION,
            },
            "sourceImageHashes": source_hashes,
            "inputFileHashes": input_file_hashes,
            "exportFileHashes": export_file_hashes,
            "parameterFiles": export_parameter_files,
        },
    }
    export["manifestSha256"] = canonical_json_sha256(export)
    output = args.out / "atlas-export.json"
    write_json(output, export)
    return result_envelope(
        "export-atlas",
        "ok",
        project,
        output,
        [
            f"Exported {len(slice_exports)} accepted Allen CCF registration(s).",
            f"Exported {len(tracks_document.get('tracks', []))} blind 3D probe track(s) with exclusive reviewed source-point membership.",
        ],
        export=export,
    )


def command_doctor(args: argparse.Namespace) -> dict[str, Any]:
    project = (
        read_json(args.project)
        if args.project
        else {
            "id": "doctor",
            "atlas": {
                "id": ATLAS_NAME,
                "version": ATLAS_VERSION,
                "voxelSizeMicrons": 25.0,
            },
            "orientation": "coronal",
            "pixelSizeMicrons": 1.0,
            "channelMappings": [],
            "slices": [],
        }
    )
    atlas = load_atlas(project, annotations=False)
    return result_envelope(
        "doctor",
        "ok",
        None,
        atlas.root_dir,
        [
            f"BrainGlobe {atlas.name} v{atlas.version} is ready.",
            f"shape={atlas.reference.shape}, resolution={atlas.resolution} um, orientation={atlas.orientation}",
            f"DeepSlice {DEEPSLICE_VERSION}, SimpleITK {sitk.Version_VersionString()}, and worker {WORKER_VERSION} are ready.",
        ],
    )


def add_common_output(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--result-json", type=Path)
    parser.add_argument("--progress-json", type=Path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="brainbuilder-worker")
    subparsers = parser.add_subparsers(dest="command", required=True)

    prepare = subparsers.add_parser("prepare")
    prepare.add_argument("--project", type=Path, required=True)
    prepare.add_argument("--out", type=Path, required=True)
    add_common_output(prepare)
    prepare.set_defaults(func=command_prepare)

    pose = subparsers.add_parser("estimate-pose")
    pose.add_argument("--project", type=Path, required=True)
    pose.add_argument("--out", type=Path, required=True)
    add_common_output(pose)
    pose.set_defaults(func=command_estimate_pose)

    register = subparsers.add_parser("register-slice")
    register.add_argument("--project", type=Path, required=True)
    register.add_argument("--slice-id", required=True)
    register.add_argument("--stage", choices=["affine", "spline"], required=True)
    register.add_argument("--out", type=Path, required=True)
    add_common_output(register)
    register.set_defaults(func=command_register_slice)

    correct = subparsers.add_parser("correct-slice")
    correct.add_argument("--project", type=Path, required=True)
    correct.add_argument("--slice-id", required=True)
    correct.add_argument("--correction-json", type=Path, required=True)
    correct.add_argument("--out", type=Path, required=True)
    add_common_output(correct)
    correct.set_defaults(func=command_correct_slice)

    register_project = subparsers.add_parser("register-project")
    register_project.add_argument("--project", type=Path, required=True)
    register_project.add_argument(
        "--stage", choices=["affine", "spline"], default="affine"
    )
    register_project.add_argument("--out", type=Path, required=True)
    add_common_output(register_project)
    register_project.set_defaults(func=command_register_project)

    export = subparsers.add_parser("export-atlas")
    export.add_argument("--project", type=Path, required=True)
    export.add_argument("--out", type=Path, required=True)
    add_common_output(export)
    export.set_defaults(func=command_export_atlas)

    review_blind_tracks = subparsers.add_parser("review-blind-tracks")
    review_blind_tracks.add_argument("--project", type=Path, required=True)
    review_blind_tracks.add_argument("--out", type=Path, required=True)
    add_common_output(review_blind_tracks)
    review_blind_tracks.set_defaults(func=command_review_blind_tracks)

    review_brain3d = subparsers.add_parser("review-brain3d")
    review_brain3d.add_argument("--project", type=Path, required=True)
    review_brain3d.add_argument("--out", type=Path, required=True)
    add_common_output(review_brain3d)
    review_brain3d.set_defaults(func=command_review_brain3d)

    doctor = subparsers.add_parser("doctor")
    doctor.add_argument("--project", type=Path)
    add_common_output(doctor)
    doctor.set_defaults(func=command_doctor)
    return parser


def print_summary(result: dict[str, Any]) -> None:
    print("BrainBuilder registration worker")
    print(f"command={result['command']}")
    print(f"stage={result['stage']}")
    if result.get("outputPath"):
        print(f"output={result['outputPath']}")
    for message in result.get("messages", []):
        print(f"message={message}")


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    result_path = getattr(args, "result_json", None)
    try:
        result = args.func(args)
        exit_code = 0 if result.get("stage") == "ok" else 1
    except WorkerBlocked as error:
        result = result_envelope(args.command, "blocked", None, None, [str(error)])
        emit_progress(args, "failed", 0, 0, str(error))
        exit_code = 2
    except (
        Exception
    ) as error:  # pragma: no cover - crash envelope is integration-tested
        traceback.print_exc(file=sys.stderr)
        result = result_envelope(
            args.command, "failed", None, None, [f"{type(error).__name__}: {error}"]
        )
        emit_progress(args, "failed", 0, 0, f"{type(error).__name__}: {error}")
        exit_code = 1
    if result_path:
        write_json(result_path, result)
    print_summary(result)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
