#!/usr/bin/env python3
"""Portable QuickNII handoff and an isolated, versioned official ABBA runner.

Export needs only NumPy, Pillow, and tifffile. The run command additionally needs
the dependencies in abba/pyproject.toml, Java 11, Maven, and elastix 5.2.0.
It never changes the source project or marks its registration as accepted.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import shutil
import subprocess
import sys
import time
import traceback
from datetime import datetime, timezone
from importlib.metadata import version
from pathlib import Path

import numpy as np
import tifffile
from PIL import Image


ABBA_VERSION = "0.11.0"
ATLAS_ID = "allen_mouse_25um"
SCHEMA_VERSION = 1


class BridgeBlocked(ValueError):
    """Inputs need preparation or a supported runtime before this can run."""


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + "\n")


def read_json(path: Path) -> dict:
    return json.loads(path.read_text())


def emit_run_progress(path: Path | None, stage: str, completed: int, total: int,
                      message: str, slice_id: str | None = None) -> None:
    if path is None:
        return
    temporary = path.with_suffix(path.suffix + ".tmp")
    write_json(temporary, {"schemaVersion": 1, "command": "run", "stage": stage,
               "completed": completed, "total": total, "failed": 0,
               "sliceID": slice_id, "sliceTitle": slice_id, "message": message,
               "updatedAt": datetime.now(timezone.utc).isoformat()})
    temporary.replace(path)


def establish_process_group() -> None:
    """Give a GUI caller one isolated process group for Python/JVM/Elastix."""
    if os.getpgrp() != os.getpid():
        os.setsid()


def orientation(pose: dict) -> dict:
    angle = float(pose.get("rotationDegrees", 0)) % 360
    if not math.isfinite(angle) or angle % 90:
        raise BridgeBlocked("Prepare a canonical raster before exporting a non-right-angle rotation.")
    return {"rotationDegrees": int(angle),
            "flipHorizontal": bool(pose.get("flipHorizontal", False)),
            "flipVertical": bool(pose.get("flipVertical", False))}


def scalar_raster(path: Path, raster_orientation: dict | None = None,
                  selection_domain: np.ndarray | None = None) -> np.ndarray:
    """Recover the scalar signal from the app's pseudocolored prepared channel.

    The maximum RGB component preserves a single pseudocolored channel's range;
    Explicit domains preserve raw RGB inside the selected section. Older
    projects retain their alpha convention. No contrast normalization occurs.
    """
    with Image.open(path) as image:
        rgba = np.asarray(image.convert("RGBA"))
    values = rgba[..., :3].max(axis=2)
    if selection_domain is None:
        values = np.rint(values.astype(float) * rgba[..., 3] / 255).astype(np.uint8)
    if raster_orientation:
        if raster_orientation["flipHorizontal"]:
            values = np.flip(values, axis=1)
        if raster_orientation["flipVertical"]:
            values = np.flip(values, axis=0)
        values = np.rot90(values, raster_orientation["rotationDegrees"] // 90)
    if selection_domain is not None:
        if selection_domain.shape != values.shape or not selection_domain.any():
            raise BridgeBlocked("Selection-domain mask is empty or differs from the canonical source grid.")
        values = np.where(selection_domain, values, 0).astype(np.uint8)
    return np.ascontiguousarray(values)


def prepared_selection_mask(record: dict, project_dir: Path) -> tuple[np.ndarray, Path] | None:
    artifacts = record.get("artifacts", {})
    canonical = record.get("canonicalRasterOrientation") is not None
    value = artifacts.get("selectionMaskPath") if canonical else artifacts.get("rawSelectionMaskPath") or artifacts.get("selectionMaskPath")
    if not value:
        return None
    path = Path(value).expanduser()
    if not path.is_absolute():
        path = project_dir / path
    if not path.is_file():
        raise BridgeBlocked(f"Selection-domain mask is missing: {path}")
    with Image.open(path) as image:
        domain = np.asarray(image.convert("L")) > 0
    if not canonical:
        pose = orientation(record.get("pose") or {})
        if pose["flipHorizontal"]:
            domain = np.flip(domain, axis=1)
        if pose["flipVertical"]:
            domain = np.flip(domain, axis=0)
        domain = np.rot90(domain, pose["rotationDegrees"] // 90)
    return np.ascontiguousarray(domain), path.resolve()


def prepared_channel(record: dict, role: str, project_dir: Path,
                     selection_domain: np.ndarray | None = None) -> tuple[np.ndarray, Path] | None:
    artifacts = record.get("artifacts", {})
    key = "structuralImagePath" if role == "structural" else "probeChannelImagePath"
    raw_key = "rawStructuralImagePath" if role == "structural" else "rawProbeChannelImagePath"
    pose_orientation = orientation(record.get("pose") or {})
    canonical_orientation = record.get("canonicalRasterOrientation")
    if canonical_orientation is not None:
        if orientation(canonical_orientation) != pose_orientation:
            raise BridgeBlocked(f"{record['id']}: canonical image orientation is stale; prepare it again.")
        path_value = artifacts.get(key)
        apply_orientation = None
    else:
        path_value = artifacts.get(raw_key) or (record.get("sourceImagePath") if role == "structural" else artifacts.get(key))
        apply_orientation = pose_orientation
    if not path_value:
        if role == "probe":
            return None
        raise BridgeBlocked(f"{record['id']}: prepared structural image is missing.")
    path = Path(path_value).expanduser()
    if not path.is_absolute():
        path = project_dir / path
    if not path.is_file():
        raise BridgeBlocked(f"{record['id']}: image file is missing: {path}")
    return scalar_raster(path, apply_orientation, selection_domain), path.resolve()


def export_bundle(project_path: Path, output: Path, slice_ids: list[str] | None = None) -> dict:
    project_path = project_path.expanduser().resolve()
    project_bytes = project_path.read_bytes()
    project = json.loads(project_bytes)
    if project.get("atlas", {}).get("id") != ATLAS_ID:
        raise BridgeBlocked(f"The ABBA bridge currently supports {ATLAS_ID} only.")
    all_slices = project.get("slices", [])
    requested = set(slice_ids or [])
    known_ids = [record["id"] for record in all_slices]
    if len(set(known_ids)) != len(known_ids):
        raise BridgeBlocked("Project slice IDs must be unique.")
    if requested - set(known_ids):
        raise BridgeBlocked(f"Unknown slice IDs: {sorted(requested - set(known_ids))}")
    selected = [s for s in all_slices if not requested or s["id"] in requested]
    if not selected:
        raise BridgeBlocked("No slices are available to export.")
    output = output.expanduser().resolve()
    if output.exists():
        raise BridgeBlocked(f"Choose a new export directory: {output}")

    # Validate and read every selected input before creating the handoff directory.
    prepared = []
    for record in selected:
        pose = record.get("pose") or {}
        anchor = np.asarray(pose.get("atlasAnchoring", []), dtype=float)
        if anchor.shape != (9,) or not np.isfinite(anchor).all():
            raise BridgeBlocked(f"{record['id']}: a finite QuickNII anchoring is required; estimate or set the plane first.")
        if np.linalg.norm(np.cross(anchor[3:6], anchor[6:9])) < 1e-8:
            raise BridgeBlocked(f"{record['id']}: QuickNII plane is degenerate.")
        pixel_size = record.get("pixelSizeMicrons") or project.get("pixelSizeMicrons")
        if not pixel_size or not math.isfinite(float(pixel_size)) or pixel_size <= 0:
            raise BridgeBlocked(f"{record['id']}: physical pixel size is missing.")
        selection = prepared_selection_mask(record, project_path.parent)
        domain = selection[0] if selection is not None else None
        mask_hashes = (project.get("provenance") or {}).get("selectionMaskHashes")
        if selection is None and mask_hashes is not None and record["id"] in mask_hashes:
            raise BridgeBlocked(f"Selection-domain mask is missing for {record['id']}; prepare it again.")
        if selection is not None and mask_hashes is not None:
            artifacts = record.get("artifacts", {})
            raw_mask = Path(artifacts.get("rawSelectionMaskPath") or artifacts["selectionMaskPath"]).expanduser()
            if not raw_mask.is_absolute():
                raw_mask = project_path.parent / raw_mask
            expected = mask_hashes.get(record["id"])
            if sha256(raw_mask) != expected:
                raise BridgeBlocked(f"Selection-domain mask changed for {record['id']}; prepare and estimate it again.")
        structural, structural_path = prepared_channel(record, "structural", project_path.parent, domain)
        probe = prepared_channel(record, "probe", project_path.parent, domain)
        if probe is not None and probe[0].shape != structural.shape:
            raise BridgeBlocked(f"{record['id']}: probe and structural image dimensions differ.")
        prepared.append((record, anchor.tolist(), float(pixel_size), structural, structural_path, probe, selection))

    output.mkdir(parents=True)
    (output / "source-project.json").write_bytes(project_bytes)
    quicknii_slices, entries = [], []
    for index, (record, anchor, pixel_size, structural, source_path, probe, selection) in enumerate(prepared):
        filename = f"section_s{index:04d}.tif"
        path = output / filename
        tifffile.imwrite(path, structural, photometric="minisblack", metadata={"axes": "YX"})
        height, width = structural.shape
        quicknii_slices.append({"filename": filename, "width": width, "height": height,
                                "nr": index, "anchoring": anchor})
        entry = {"sliceID": record["id"], "index": index, "width": width, "height": height,
                 "pixelSizeMicrons": pixel_size, "anchoring": anchor,
                 "rasterOrientation": orientation(record.get("pose") or {}),
                 "structuralFile": filename, "structuralSHA256": sha256(path),
                 "sourceStructuralPath": str(source_path), "sourceStructuralSHA256": sha256(source_path)}
        if probe is not None:
            probe_file = f"section_s{index:04d}_probe.tif"
            tifffile.imwrite(output / probe_file, probe[0], photometric="minisblack", metadata={"axes": "YX"})
            entry.update(probeFile=probe_file, probeSHA256=sha256(output / probe_file),
                         sourceProbePath=str(probe[1]), sourceProbeSHA256=sha256(probe[1]))
        if selection is not None:
            mask_file = f"section_s{index:04d}_selection.tif"
            tifffile.imwrite(output / mask_file, selection[0].astype(np.uint8) * 255, photometric="minisblack")
            entry.update(selectionMaskFile=mask_file, selectionMaskSHA256=sha256(output / mask_file),
                         sourceSelectionMaskPath=str(selection[1]), sourceSelectionMaskSHA256=sha256(selection[1]),
                         scalarSignalContract="max RGB inside explicit selection domain; zero outside; source alpha ignored")
        else:
            entry["scalarSignalContract"] = "legacy max RGB multiplied by source alpha/255"
        entries.append(entry)
    quicknii_path = output / "quicknii.json"
    write_json(quicknii_path, {"name": project["id"], "target": "ABA_Mouse_CCFv3_2017_25um",
                              "aligner": "BrainBuilder handoff to official ABBA", "slices": quicknii_slices})
    manifest_path = output / "manifest.json"
    manifest = {"schemaVersion": SCHEMA_VERSION, "createdAt": datetime.now(timezone.utc).isoformat(),
                "projectID": project["id"], "projectPath": str(project_path),
                "projectSnapshotFile": "source-project.json",
                "projectSHA256": hashlib.sha256(project_bytes).hexdigest(), "atlas": project["atlas"],
                "abbaPythonVersion": ABBA_VERSION, "quickniiFile": quicknii_path.name,
                "quickniiSHA256": sha256(quicknii_path), "slices": entries,
                "rasterIntensity": "max(R,G,B); explicit selection domain when present, otherwise legacy alpha/255; no contrast normalization",
                "quickniiCoordinates": "RAS 25um voxel units; o + u*x/width + v*y/height",
                "abbaImportApproximation": "ABBA applies the median slicing angle to all imported sections.",
                "abbaQuickNIIBoundaryOriginMM": [13.2, 8.0, 11.4],
                "registrationStatus": "exported_for_official_abba; not_registered_or_accepted"}
    write_json(manifest_path, manifest)
    shutil.copyfile(Path(__file__), output / "abba_bridge.py")
    review_module = Path(__file__).with_name("abba_review.py")
    if review_module.is_file():
        shutil.copyfile(review_module, output / review_module.name)
    dependency_file = Path(__file__).parent / "abba" / "pyproject.toml"
    if dependency_file.is_file():
        (output / "abba").mkdir()
        shutil.copyfile(dependency_file, output / "abba" / "pyproject.toml")
        local_launcher = dependency_file.parent / "run-local.command"
        if local_launcher.is_file():
            shutil.copyfile(local_launcher, output / "abba" / "run-local.command")
            (output / "abba" / "run-local.command").chmod(0o755)
    launch = output / "run-abba.command"
    launch.write_text('#!/bin/sh\nset -eu\ncd "$(dirname "$0")"\n'
                      'runtime=${BRAINBUILDER_ABBA_RUNTIME:-"$HOME/.cache/brainbuilder-abba"}\n'
                      'if [ -x "$runtime/venv/bin/python" ] && [ -x abba/run-local.command ]; then\n'
                      '  exec abba/run-local.command --bundle . "$@"\nfi\n'
                      'exec uv run --project abba python abba_bridge.py run --bundle . "$@"\n')
    launch.chmod(0o755)
    (output / "OPEN-IN-ABBA.txt").write_text(
        "In Fiji with the official ABBA plugin, start the Allen CCFv3 atlas and choose\n"
        "Import > ABBA - Import QuickNII Project, then select quicknii.json.\n"
        "The *_probe.tif sidecars are for inspection; they are not registration channels.\n"
        "ABBA replaces per-section slicing angles with their median.\n\n"
        "This Mac can reuse ~/.cache/brainbuilder-abba via run-abba.command.\n"
        "Elsewhere, install Java 11, Maven, uv and elastix/transformix 5.2.0.\n"
        "The official wrapper requires actual bin/elastix and bin/transformix\n"
        "paths in the distribution's bin/lib layout, without whitespace.\n"
        "On this configured Mac, run:\n"
        "./run-abba.command --output /new/result/directory --stage import\n"
        "./run-abba.command --output /new/result/directory --stage spline\n\n"
        "On another configured machine, pass the native binary paths:\n"
        "./run-abba.command --output /new/result/directory --stage spline "
        "--elastix /path/to/bin/elastix --transformix /path/to/bin/transformix\n\n"
        "The runner saves official .abba state, raw XYZ millimeter coordinate TIFFs,\n"
        "and AP/DV/ML micrometer coordinate TIFFs in the original image grid.\n"
        "These are registration proposals and require anatomical review.\n")
    return {"status": "exported", "projectID": project["id"], "outputDirectory": str(output),
            "quickniiPath": str(quicknii_path), "manifestPath": str(manifest_path),
            "launchScriptPath": str(launch), "sliceCount": len(entries)}


def load_bundle(bundle: Path) -> dict:
    manifest = read_json(bundle / "manifest.json")
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        raise BridgeBlocked("Unsupported ABBA bundle schema.")
    if manifest.get("projectSnapshotFile") and sha256(bundle / manifest["projectSnapshotFile"]) != manifest["projectSHA256"]:
        raise BridgeBlocked("Bundle source project snapshot checksum differs.")
    for filename, expected in [(manifest["quickniiFile"], manifest["quickniiSHA256"])]:
        if sha256(bundle / filename) != expected:
            raise BridgeBlocked(f"Bundle checksum differs: {filename}")
    for entry in manifest["slices"]:
        for role in ["structural", "probe", "selectionMask"]:
            if entry.get(role + "File") and sha256(bundle / entry[role + "File"]) != entry[role + "SHA256"]:
                raise BridgeBlocked(f"Bundle checksum differs: {entry[role + 'File']}")
    return manifest


def abba_xyz_to_asr_um(xyz: np.ndarray) -> np.ndarray:
    """ABBA 0.11 BrainGlobe map uses ImageJ XYZ = array RL, SI, AP, in mm."""
    return np.ascontiguousarray(xyz[[2, 1, 0]] * 1000, dtype=np.float32)


def match_official_slices(slices, entries: list[dict]) -> list:
    """ABBA reorders sections by depth; never associate results by list index."""
    matched = {}
    for item in slices:
        name = str(item.getName())
        candidates = [entry for entry in entries if Path(entry["structuralFile"]).stem in name]
        if len(candidates) != 1 or candidates[0]["sliceID"] in matched:
            raise RuntimeError(f"Cannot map ABBA slice name to a unique source: {name}")
        matched[candidates[0]["sliceID"]] = item
    if len(matched) != len(entries):
        raise RuntimeError("Official ABBA imported a different slice count.")
    return [matched[entry["sliceID"]] for entry in entries]


def verify_stage(slices: list, expected_counts: list[int], errors: list[str], stage: str) -> None:
    counts = [int(item.getNumberOfRegistrations()) for item in slices]
    if counts != expected_counts or errors:
        raise RuntimeError(f"ABBA {stage} did not complete: registrations {counts}, "
                           f"expected {expected_counts}; errors: {'; '.join(errors)}")


def elastix_binary_version(path: Path, name: str) -> str:
    """The official Unix wrapper derives ../lib and ../bin from this path."""
    path = path.resolve()
    if path.name != name or path.parent.name != "bin" or any(c.isspace() for c in str(path)):
        raise BridgeBlocked(f"Official ABBA requires the actual bin/{name} executable in a path without whitespace.")
    environment = os.environ.copy()
    library_variable = "DYLD_LIBRARY_PATH" if sys.platform == "darwin" else "LD_LIBRARY_PATH"
    environment[library_variable] = str(path.parent.parent / "lib")
    return subprocess.check_output([str(path), "--version"], text=True, env=environment).strip()


def expected_quicknii_import(entry: dict, slicing_to_atlas: np.ndarray) -> np.ndarray:
    """Reproduce ABBA 0.11 QuickNII import geometry independently in NumPy.

    CenterZeroRegistration centers on (size - 1)/2, while QuickNII import
    translates by size/2. Import's flat transform also retains the x/y
    components of the plane normal, after MoveSlice has applied slice depth.
    Both details are material for oblique slices and are preserved here.
    """
    anchor = np.asarray(entry["anchoring"], dtype=float).reshape(3, 3)
    u, v = anchor[1] / entry["width"], anchor[2] / entry["height"]
    normal = np.cross(u, v)
    normal /= np.linalg.norm(normal)
    pixel_to_quicknii = np.eye(4)
    pixel_to_quicknii[:3] = np.column_stack((u, v, normal, anchor[0]))
    quicknii_to_xyz = np.asarray([[-0.025, 0, 0, 11.4], [0, 0, -0.025, 8],
                                 [0, -0.025, 0, 13.2], [0, 0, 0, 1]])
    local = np.linalg.inv(slicing_to_atlas) @ quicknii_to_xyz @ pixel_to_quicknii
    depth = local[2, 3]
    local[2] = [0, 0, 1, 0]
    centered_and_moved = np.eye(4)
    centered_and_moved[:3, 3] = [0.5, 0.5, depth]
    return slicing_to_atlas @ local @ centered_and_moved


def verify_single_slice_import(slice_source, entry: dict, slicing_to_atlas) -> dict:
    """Check official import against the source-derived independent formula."""
    from jpype.types import JArray, JDouble
    to_atlas = slice_source.getSlicePixToCCFRealTransform(0, 0.005, 200).inverse()
    matrix = np.eye(4)
    matrix[:3] = np.asarray(slicing_to_atlas.getRowPackedCopy()).reshape(3, 4)
    expected_transform = expected_quicknii_import(entry, matrix)
    anchor = np.asarray(entry["anchoring"]).reshape(3, 3)
    max_error_um, max_input_displacement_um = 0.0, 0.0
    for x in [0, (entry["width"] - 1) / 2, entry["width"] - 1]:
        for y in [0, (entry["height"] - 1) / 2, entry["height"] - 1]:
            expected = (expected_transform @ [x, y, 0, 1])[:3]
            quicknii = anchor[0] + anchor[1] * x / entry["width"] + anchor[2] * y / entry["height"]
            input_xyz = np.asarray([11.4 - 0.025 * quicknii[0], 8 - 0.025 * quicknii[2], 13.2 - 0.025 * quicknii[1]])
            target = JArray(JDouble)(3)
            to_atlas.apply(JArray(JDouble)([float(x), float(y), 0.0]), target)
            max_error_um = max(max_error_um, float(np.linalg.norm(np.asarray(target) - expected) * 1000))
            max_input_displacement_um = max(max_input_displacement_um, float(np.linalg.norm(expected - input_xyz) * 1000))
    if max_error_um > 0.01:
        raise RuntimeError(f"ABBA import disagrees with the independent import formula by {max_error_um:.6f} um.")
    return {"independentFormulaMaxErrorMicrons": max_error_um,
            "inputPlaneMaxDisplacementMicrons": max_input_displacement_um,
            "expectedPixelToAtlasXYZMillimeters": expected_transform.tolist()}


def run_official(bundle: Path, output: Path, stage: str, elastix: Path | None,
                 transformix: Path | None, progress_path: Path | None = None) -> dict:
    bundle, output = bundle.resolve(), output.resolve()
    manifest = load_bundle(bundle)
    total = len(manifest["slices"]) * {"import": 1, "affine": 2, "spline": 3}[stage]
    emit_run_progress(progress_path, "loadingAtlas", 0, total, "Loading official ABBA and Allen atlas.")
    if version("abba-python") != ABBA_VERSION:
        raise BridgeBlocked(f"Use the isolated runtime with abba-python=={ABBA_VERSION}.")
    if output.exists():
        raise BridgeBlocked(f"Choose a new results directory: {output}")
    if stage != "import" and (not elastix or not transformix):
        raise BridgeBlocked("Affine/spline requires explicit --elastix and --transformix paths.")
    output.mkdir(parents=True)
    import scyjava
    scyjava.config.add_options("-Xmx4g")
    from abba_python.abba import Abba
    from scyjava import jimport
    abba = Abba(ATLAS_ID, headless=True, print_config=False)
    File = jimport("java.io.File")
    System = jimport("java.lang.System")
    VersionUtils = jimport("org.scijava.util.VersionUtils")
    runtime = {"javaVersion": str(System.getProperty("java.version")),
               "javaHome": str(System.getProperty("java.home")),
               "javaArchitecture": str(System.getProperty("os.arch")),
               "imageToAtlasRegisterVersion": str(VersionUtils.getVersion(jimport("ch.epfl.biop.atlas.aligner.MultiSlicePositioner")))}
    # The official Python GUI does this in add_brainglobe_atlases; Abba()
    # alone does not. QuickNII otherwise silently uses an identity atlas map.
    DeepSliceHelper = jimport("ch.epfl.biop.atlas.aligner.DeepSliceHelper")
    DeepSliceHelper.addMouseCompatibleAtlas(ATLAS_ID)
    if not DeepSliceHelper.isDeepSliceMouseCompatible(ATLAS_ID):
        raise RuntimeError("Official ABBA did not register the QuickNII atlas convention.")
    if abba.atlas.atlas.metadata["version"] != manifest["atlas"]["version"]:
        raise BridgeBlocked("Installed BrainGlobe atlas version differs from the exported project.")
    from jpype import JProxy
    errors = []
    error_logger = JProxy("java.util.function.BiConsumer", dict={
        "accept": lambda title, message: errors.append(f"{title}: {message}")})
    abba.mp.subscribeToErrorMessages(error_logger)
    if stage != "import":
        runtime["elastixVersion"] = elastix_binary_version(elastix, "elastix")
        runtime["transformixVersion"] = elastix_binary_version(transformix, "transformix")
        abba.set_elastix_path(str(elastix.resolve()))
        abba.set_transformix_path(str(transformix.resolve()))
    stage_start = time.monotonic()
    abba.import_slices_from_quicknii(File(str(bundle / manifest["quickniiFile"])), False)
    abba.wait_for_end_of_tasks()
    if abba.get_n_slices() != len(manifest["slices"]):
        raise RuntimeError("Official ABBA imported a different slice count.")
    slices = match_official_slices(abba.mp.getSlices(), manifest["slices"])
    expected_counts = [1] * len(slices)
    verify_stage(slices, expected_counts, errors, "QuickNII import")
    stages = [{"stage": "import", "registrationCounts": expected_counts.copy(),
               "elapsedSeconds": time.monotonic() - stage_start}]
    import_validation = [verify_single_slice_import(item, entry, abba.mp.getReslicedAtlas().getSlicingTransformToAtlas())
                         for item, entry in zip(slices, manifest["slices"], strict=True)]
    emit_run_progress(progress_path, "registeringSlices", len(slices), total,
                      "QuickNII import and independent coordinate checks passed.")
    # ABBA dispatches selected slices concurrently. Select one at a time so a
    # montage cannot launch dozens of Elastix jobs and exhaust local memory.
    for registration_stage in (["affine", "spline"] if stage == "spline" else ["affine"] if stage == "affine" else []):
        stage_start = time.monotonic()
        for index, slice_source in enumerate(slices):
            completed = len(slices) * (1 if registration_stage == "affine" else 2) + index
            slice_id = manifest["slices"][index]["sliceID"]
            emit_run_progress(progress_path, "registeringSlices", completed, total,
                              f"Official ABBA {registration_stage}: {index + 1}/{len(slices)}.", slice_id)
            abba.deselect_all_slices()
            abba.mp.selectSlice(slice_source)
            print(f"ABBA {registration_stage} {index + 1}/{len(slices)}: {manifest['slices'][index]['sliceID']}", file=sys.stderr, flush=True)
            if registration_stage == "affine":
                abba.register_slices_elastix_affine("0", "0", 40.0, False)
            else:
                abba.register_slices_elastix_spline("0", "0", 10, 20.0, False)
            abba.wait_for_end_of_tasks()
            expected_counts[index] += 1
            verify_stage(slices, expected_counts, errors, registration_stage)
            emit_run_progress(progress_path, "registeringSlices", completed + 1, total,
                              f"Official ABBA {registration_stage} completed: {index + 1}/{len(slices)}.", slice_id)
            write_json(output / "progress.json", {"stage": registration_stage,
                       "completedSlices": index + 1, "sliceCount": len(slices),
                       "registrationCounts": expected_counts})
        stages.append({"stage": registration_stage, "registrationCounts": expected_counts.copy(),
                       "elapsedSeconds": time.monotonic() - stage_start})
    state_path = output / "registration.abba"
    emit_run_progress(progress_path, "finalizing", total, total, "Saving official registration state and coordinate fields.")
    if not abba.state_save(File(str(state_path))):
        raise RuntimeError("Official ABBA did not save its registration state.")
    Export = jimport("ch.epfl.biop.atlas.aligner.DeformationFieldToImagePlus")
    results = []
    for index, entry in enumerate(manifest["slices"]):
        emit_run_progress(progress_path, "finalizing", total, total,
                          f"Saving atlas coordinate field: {index + 1}/{len(slices)}.", entry["sliceID"])
        slice_source = slices[index]
        image = Export.export(slice_source, 0, 1, 0, 0.005, 200)
        xyz = np.stack([np.asarray(image.getStack().getPixels(c + 1), dtype=np.float32).reshape(image.getHeight(), image.getWidth()) for c in range(3)])
        if xyz.shape != (3, entry["height"], entry["width"]) or not np.isfinite(xyz).all():
            raise RuntimeError(f"Invalid atlas coordinate field for {entry['sliceID']}.")
        raw_path = output / f"section_s{index:04d}_abba_xyz_mm.tif"
        asr_path = output / f"section_s{index:04d}_atlas_asr_um.tif"
        tifffile.imwrite(raw_path, xyz, photometric="minisblack", metadata={"axes": "CYX"})
        tifffile.imwrite(asr_path, abba_xyz_to_asr_um(xyz), photometric="minisblack", metadata={"axes": "CYX"})
        results.append({"sliceID": entry["sliceID"], "structuralSHA256": entry["structuralSHA256"],
                        "officialSliceName": str(slice_source.getName()),
                        "completedRegistrationCount": int(slice_source.getNumberOfRegistrations()),
                        "width": entry["width"], "height": entry["height"],
                        "abbaXYZMillimetersFile": raw_path.name, "atlasCoordinatesFile": asr_path.name,
                        "atlasCoordinatesSHA256": sha256(asr_path)})
    result = {"schemaVersion": SCHEMA_VERSION, "status": "official_abba_completed", "stage": stage,
              "projectID": manifest["projectID"], "projectSHA256": manifest["projectSHA256"],
              "bundlePath": str(bundle), "bundleManifestPath": str(bundle / "manifest.json"),
              "bundleManifestSHA256": sha256(bundle / "manifest.json"),
              "abbaPythonVersion": ABBA_VERSION, "atlas": manifest["atlas"],
              "runtime": runtime, "completedStages": stages,
              "quickNIIImportValidation": import_validation,
              "coordinateFrame": "BRAINGLOBE_PHYSICAL_ASR_UM", "coordinateOrder": ["AP", "DV", "ML"],
              "coordinateUnit": "micrometre", "coordinateImageAxes": "CYX", "pixelOrigin": "zero_based_pixel_centres",
              "stateFile": state_path.name, "stateSHA256": sha256(state_path),
              "slices": results, "anatomicalReview": "required"}
    write_json(output / "result.json", result)
    abba.close()
    abba.ij.dispose()
    return {**result, "outputDirectory": str(output), "resultPath": str(output / "result.json")}


def validate_result(bundle: Path, result_path: Path) -> dict:
    """Check identity and dense transform shape before a consumer uses a result."""
    manifest, result = load_bundle(bundle), read_json(result_path)
    if result.get("status") != "official_abba_completed" or result.get("schemaVersion") != SCHEMA_VERSION:
        raise BridgeBlocked("Result is not a completed, supported official ABBA run.")
    if result.get("bundleManifestSHA256") != sha256(bundle / "manifest.json"):
        raise BridgeBlocked("Result belongs to a different export bundle.")
    if result.get("projectSHA256") != manifest["projectSHA256"] or result.get("projectID") != manifest["projectID"]:
        raise BridgeBlocked("Result project identity differs.")
    if result.get("atlas") != manifest["atlas"] or result.get("abbaPythonVersion") != ABBA_VERSION:
        raise BridgeBlocked("Result atlas or ABBA version differs.")
    if result.get("coordinateFrame") != "BRAINGLOBE_PHYSICAL_ASR_UM" or result.get("coordinateOrder") != ["AP", "DV", "ML"]:
        raise BridgeBlocked("Unsupported result coordinate frame.")
    if (result.get("coordinateUnit") != "micrometre" or result.get("coordinateImageAxes") != "CYX"
            or result.get("pixelOrigin") != "zero_based_pixel_centres"):
        raise BridgeBlocked("Unsupported result coordinate image convention.")
    expected_count = {"import": 1, "affine": 2, "spline": 3}.get(result.get("stage"))
    if expected_count is None:
        raise BridgeBlocked("Unsupported result registration stage.")
    if result.get("stateSHA256") and sha256(result_path.parent / result["stateFile"]) != result["stateSHA256"]:
        raise BridgeBlocked("Official registration state checksum differs.")
    originals = {entry["sliceID"]: entry for entry in manifest["slices"]}
    if [s["sliceID"] for s in result["slices"]] != list(originals):
        raise BridgeBlocked("Result slice identity/order differs.")
    for entry in result["slices"]:
        original = originals[entry["sliceID"]]
        if entry.get("width") != original["width"] or entry.get("height") != original["height"]:
            raise BridgeBlocked(f"Result source grid dimensions differ: {entry['sliceID']}")
        if entry.get("completedRegistrationCount") != expected_count:
            raise BridgeBlocked(f"Result did not complete its declared registration stage: {entry['sliceID']}")
        if entry["structuralSHA256"] != original["structuralSHA256"]:
            raise BridgeBlocked("Result refers to different structural pixels.")
        path = result_path.parent / entry["atlasCoordinatesFile"]
        coords = tifffile.imread(path)
        if sha256(path) != entry["atlasCoordinatesSHA256"] or coords.shape != (3, original["height"], original["width"]) or not np.isfinite(coords).all():
            raise BridgeBlocked(f"Invalid result coordinate image: {entry['sliceID']}")
    return {"status": "validated", "projectID": manifest["projectID"], "sliceCount": len(originals),
            "resultPath": str(result_path.resolve()), "anatomicalReview": "required"}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    export = commands.add_parser("export")
    export.add_argument("--project", type=Path, required=True)
    export.add_argument("--output", type=Path, required=True)
    export.add_argument("--slice-id", action="append")
    export.add_argument("--result-json", type=Path)
    run = commands.add_parser("run")
    run.add_argument("--bundle", type=Path, required=True)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--stage", choices=["import", "affine", "spline"], default="import")
    run.add_argument("--elastix", type=Path)
    run.add_argument("--transformix", type=Path)
    run.add_argument("--result-json", type=Path)
    run.add_argument("--progress-json", type=Path)
    run.add_argument("--process-group", action="store_true")
    validate = commands.add_parser("validate-result")
    validate.add_argument("--bundle", type=Path, required=True)
    validate.add_argument("--result", type=Path, required=True)
    review = commands.add_parser("prepare-review")
    review.add_argument("--bundle", type=Path, required=True)
    review.add_argument("--result", type=Path, required=True)
    review.add_argument("--out", type=Path, required=True)
    review.add_argument("--result-json", type=Path)
    args = parser.parse_args()
    project_id = None
    try:
        if args.command == "export":
            project_id = read_json(args.project).get("id")
            result = export_bundle(args.project, args.output, args.slice_id)
        elif args.command == "run":
            if args.process_group:
                establish_process_group()
            result = run_official(args.bundle, args.output, args.stage, args.elastix, args.transformix, args.progress_json)
            validate_result(args.bundle, Path(result["resultPath"]))
            project_id = result["projectID"]
            if args.progress_json:
                previous = read_json(args.progress_json)
                emit_run_progress(args.progress_json, "completed", previous["total"], previous["total"],
                                  "Official ABBA results saved and validated; anatomical review required.")
        elif args.command == "prepare-review":
            validated = validate_result(args.bundle, args.result)
            project_id = validated["projectID"]
            from abba_review import prepare_review
            result = prepare_review(args.bundle, args.result, args.out)
        else:
            result = validate_result(args.bundle, args.result)
        result_stage, message, exit_code = "ok", "Official ABBA handoff exported." if args.command == "export" else result["status"], 0
    except Exception as error:
        result_stage = "blocked" if isinstance(error, BridgeBlocked) else "failed"
        message, exit_code = str(error), 2 if result_stage == "blocked" else 1
        result = {"status": result_stage, "error": message}
        if getattr(args, "progress_json", None):
            previous = read_json(args.progress_json) if args.progress_json.exists() else {"completed": 0, "total": 0}
            emit_run_progress(args.progress_json, "failed", previous["completed"], previous["total"], message)
        if result_stage == "failed":
            traceback.print_exc(file=sys.stderr)
    if getattr(args, "result_json", None):
        write_json(args.result_json, {"command": {"prepare-review": "abba-review", "run": "abba-run"}.get(args.command, "abba-export"),
                                    "stage": result_stage, "projectID": project_id,
                                    "outputPath": result.get("reviewPath", result.get("resultPath", result.get("outputDirectory"))), "messages": [message],
                                    "project": None, "slice": None, "export": None})
    print(json.dumps(result, allow_nan=False))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
