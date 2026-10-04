from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import brainbuilder_worker as worker  # noqa: E402


def synthetic_atlas(tmp_path: Path) -> worker.AtlasData:
    annotation = np.full((100, 100, 100), 42, dtype=np.uint32)
    return worker.AtlasData(
        name=worker.ATLAS_NAME,
        version=worker.ATLAS_VERSION,
        reference=np.zeros_like(annotation, dtype=np.uint16),
        annotation=annotation,
        resolution=(25.0, 25.0, 25.0),
        orientation="asr",
        structures={
            42: {
                "id": 42,
                "acronym": "T",
                "name": "Test",
                "rgb_triplet": [1, 2, 3],
            }
        },
        root_dir=tmp_path,
    )


def blind_project() -> tuple[dict, list[str], list[str]]:
    slices: list[dict] = []
    first_track_ids: list[str] = []
    second_track_ids: list[str] = []
    for slice_index, slice_id in enumerate(("slice-a", "slice-b", "slice-c")):
        candidates: list[dict] = []
        for track_index, (label, ml) in enumerate((("one", 300.0), ("two", 900.0))):
            candidate_id = f"{slice_id}-{label}"
            atlas_points: list[dict] = []
            source_points: list[dict] = []
            for local_index in range(2):
                source_id = f"{candidate_id}-point-{local_index}"
                x = float(track_index * 20 + local_index)
                y = float(slice_index * 10 + local_index)
                atlas_points.append(
                    {
                        "slicePoint": {"x": x, "y": y},
                        "apMicrons": 200.0 + slice_index * 20.0 + local_index * 5.0,
                        "dorsalVentralMicrons": 300.0
                        + slice_index * 180.0
                        + local_index * 40.0,
                        "rightLeftMicrons": ml + slice_index * 8.0 + local_index * 2.0,
                    }
                )
                source_points.append(
                    {"pointId": source_id, "x": x, "y": y, "inlier": True}
                )
                (first_track_ids if label == "one" else second_track_ids).append(
                    source_id
                )
            candidates.append(
                {
                    "candidateId": candidate_id,
                    "reviewAccepted": True,
                    "atlasPoints": atlas_points,
                    "points": source_points,
                }
            )
        slices.append(
            {
                "id": slice_id,
                "status": "accepted",
                "probeTrackCandidates": candidates,
            }
        )
    return {"slices": slices}, sorted(first_track_ids), sorted(second_track_ids)


def review_state(
    groups: list[tuple[str, list[str]]],
    unassigned: list[str] | None = None,
) -> dict:
    return {
        "schemaVersion": 1,
        "groups": [
            {"groupId": group_id, "sourcePointIDs": list(source_ids)}
            for group_id, source_ids in groups
        ],
        "unassignedSourcePointIDs": list(unassigned or []),
        "usableForNavigation": False,
    }


def reconstruct_document(
    tmp_path: Path,
    name: str,
    project: dict,
    atlas: worker.AtlasData,
) -> dict:
    output = tmp_path / name
    output.mkdir()
    tracks_path, _ = worker.reconstruct_probe_tracks(project, atlas, output)
    return json.loads((output / tracks_path).read_text(encoding="utf-8"))


def memberships(document: dict) -> dict[str, list[str]]:
    return {
        str(track["groupId"]): list(track["sourcePointIDs"])
        for track in document["tracks"]
    }


def test_explicit_partition_supports_split_merge_and_reassignment(
    tmp_path: Path,
) -> None:
    project, first_ids, second_ids = blind_project()
    atlas = synthetic_atlas(tmp_path)

    project["blindTrackReview"] = review_state(
        [("group-one", first_ids), ("group-two", second_ids)]
    )
    split = reconstruct_document(tmp_path, "split", project, atlas)
    assert memberships(split) == {
        "group-one": first_ids,
        "group-two": second_ids,
    }
    assert split["reviewState"] == project["blindTrackReview"]
    assert split["usableForNavigation"] is False
    assert all(track["usableForNavigation"] is False for track in split["tracks"])

    project["blindTrackReview"] = review_state(
        [("merged", list(reversed(first_ids + second_ids)))]
    )
    merged = reconstruct_document(tmp_path, "merged", project, atlas)
    assert memberships(merged) == {"merged": sorted(first_ids + second_ids)}
    assert len(merged["tracks"]) == 1

    moved = first_ids[-1]
    project["blindTrackReview"] = review_state(
        [
            ("group-one", first_ids[:-1]),
            ("group-two", second_ids + [moved]),
        ]
    )
    reassigned = reconstruct_document(tmp_path, "reassigned", project, atlas)
    assert memberships(reassigned) == {
        "group-one": first_ids[:-1],
        "group-two": sorted(second_ids + [moved]),
    }
    assert reassigned["reviewedTrackSetSha256"] != split["reviewedTrackSetSha256"]
    assert reassigned["reviewStateSha256"] != split["reviewStateSha256"]

    project["blindTrackReview"] = review_state(
        [("group-one", first_ids[:-1]), ("group-two", second_ids)],
        [moved],
    )
    with_unassigned = reconstruct_document(tmp_path, "with-unassigned", project, atlas)
    assert memberships(with_unassigned) == {
        "group-one": first_ids[:-1],
        "group-two": second_ids,
    }
    assert with_unassigned["unassignedSourcePointIDs"] == [moved]


@pytest.mark.parametrize("failure", ["overlap", "omission", "unknown", "one-slice"])
def test_explicit_partition_validation_fails_closed(
    tmp_path: Path,
    failure: str,
) -> None:
    project, first_ids, second_ids = blind_project()
    atlas = synthetic_atlas(tmp_path)
    groups = [("group-one", list(first_ids)), ("group-two", list(second_ids))]
    if failure == "overlap":
        groups[1][1].append(first_ids[0])
        match = "more than one group"
    elif failure == "omission":
        groups[0][1].pop()
        match = "omitted"
    elif failure == "unknown":
        groups[0][1][0] = "unknown-point"
        match = "unknown source-point"
    else:
        groups[0] = ("group-one", first_ids[:2] + second_ids[:1])
        match = "span at least 2 accepted slices"
    project["blindTrackReview"] = review_state(groups)
    with pytest.raises(worker.WorkerBlocked, match=match):
        reconstruct_document(tmp_path, f"invalid-{failure}", project, atlas)


def test_omitted_explicit_partition_cannot_be_hidden_by_lock(tmp_path: Path) -> None:
    project, _, _ = blind_project()
    project["blindReviewLocked"] = True
    with pytest.raises(worker.WorkerBlocked, match="locked blind review requires"):
        reconstruct_document(tmp_path, "locked", project, synthetic_atlas(tmp_path))


def test_review_command_blocks_rebuild_after_lock(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    project, first_ids, second_ids = blind_project()
    project["blindReviewLocked"] = True
    project["blindTrackReview"] = review_state(
        [("group-one", first_ids), ("group-two", second_ids)]
    )
    monkeypatch.setattr(
        worker,
        "read_json",
        lambda path: (
            project
            if path.name == "project.json"
            else json.loads(path.read_text(encoding="utf-8"))
        ),
    )
    monkeypatch.setattr(worker, "project_blockers", lambda _project: [])
    with pytest.raises(worker.WorkerBlocked, match="review is locked"):
        worker.command_review_blind_tracks(
            argparse.Namespace(project=tmp_path / "project.json", out=tmp_path / "out")
        )


def test_review_command_returns_swift_friendly_preview(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    project, first_ids, second_ids = blind_project()
    project["id"] = "blind-review-project"
    project["blindTrackReview"] = review_state(
        [("group-one", first_ids), ("group-two", second_ids)]
    )
    monkeypatch.setattr(
        worker,
        "read_json",
        lambda path: (
            project
            if path.name == "project.json"
            else json.loads(path.read_text(encoding="utf-8"))
        ),
    )
    monkeypatch.setattr(worker, "project_blockers", lambda _project: [])
    monkeypatch.setattr(
        worker,
        "load_atlas",
        lambda _project, annotations: synthetic_atlas(tmp_path),
    )

    result = worker.command_review_blind_tracks(
        argparse.Namespace(project=tmp_path / "project.json", out=tmp_path / "out")
    )

    assert result["stage"] == "ok"
    assert result["blindTrackReviewPreview"]["schemaVersion"] == 1
    assert len(result["blindTrackReviewPreview"]["tracks"]) == 2
    assert result["blindTrackReviewPreview"]["usableForNavigation"] is False
    assert (
        json.loads(Path(result["outputPath"]).read_text(encoding="utf-8"))
        == result["blindTrackReviewPreview"]
    )


def test_review_preview_has_exact_compact_contract(tmp_path: Path) -> None:
    project, first_ids, second_ids = blind_project()
    project["blindTrackReview"] = review_state(
        [("group-one", first_ids), ("group-two", second_ids)]
    )
    document = reconstruct_document(
        tmp_path, "preview", project, synthetic_atlas(tmp_path)
    )
    preview = worker._blind_track_review_preview(document)
    assert set(preview) == {
        "schemaVersion",
        "reviewedTrackSetSha256",
        "reviewStateSha256",
        "tracks",
        "unassignedSourcePointIDs",
        "usableForNavigation",
    }
    assert set(preview["tracks"][0]) == {
        "groupId",
        "trackId",
        "fitDigest",
        "sourcePointIDs",
        "pointCount",
        "distinctSliceCount",
        "rmseMicrometres",
        "supportLengthMicrometres",
        "usableForNavigation",
    }
    assert all(track["usableForNavigation"] is False for track in preview["tracks"])
    assert preview["usableForNavigation"] is False
    assert (
        worker.build_parser()
        .parse_args(
            [
                "review-blind-tracks",
                "--project",
                str(tmp_path / "project.json"),
                "--out",
                str(tmp_path / "out"),
            ]
        )
        .func
        is worker.command_review_blind_tracks
    )


def test_plan_roi_and_colony_changes_do_not_affect_reviewed_tracks_or_digests(
    tmp_path: Path,
) -> None:
    project, first_ids, second_ids = blind_project()
    project["blindTrackReview"] = review_state(
        [("group-one", first_ids), ("group-two", second_ids)]
    )
    atlas = synthetic_atlas(tmp_path)
    baseline = reconstruct_document(tmp_path, "baseline", project, atlas)

    project["brain3dContext"] = {
        "blindReviewLocked": True,
        "handoff": {
            "handoff_id": "different-plan",
            "insertion_snapshots": [{"insertion_snapshot_id": "changed"}],
            "roi_sets": [{"roi_set_id": "different-roi"}],
        },
    }
    project["colonySubjectReceipt"] = {
        "publicId": "ML-CHANGED",
        "subjectRecordSha256": "f" * 64,
        "usableForNavigation": False,
    }
    project["brain3dReview"] = {"suggestions": ["must-not-enter-blind-fit"]}
    changed = reconstruct_document(tmp_path, "changed-context", project, atlas)

    assert changed["reviewedTrackSetSha256"] == baseline["reviewedTrackSetSha256"]
    assert changed["reviewStateSha256"] == baseline["reviewStateSha256"]
    assert changed["tracks"] == baseline["tracks"]
    assert changed["unassignedSourcePointIDs"] == baseline["unassignedSourcePointIDs"]
