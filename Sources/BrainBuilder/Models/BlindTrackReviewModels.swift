import Foundation

/// Explicit blind-only source-point membership. It contains no Brain3D plan,
/// ROI, shank count, or planned coordinate and is safe to persist before lock.
struct BlindTrackReviewGroup: Codable, Identifiable, Hashable, Sendable {
    var id: String { groupId }
    var groupId: String
    var sourcePointIDs: [String]
}

struct BlindTrackReviewState: Codable, Hashable, Sendable {
    var schemaVersion: Int = 1
    var groups: [BlindTrackReviewGroup]
    var unassignedSourcePointIDs: [String]
    var usableForNavigation: Bool = false
}

struct BlindObservedTrackPreview: Codable, Identifiable, Hashable, Sendable {
    var id: String { trackId }
    var groupId: String
    var trackId: String
    var fitDigest: String
    var sourcePointIDs: [String]
    var pointCount: Int
    var distinctSliceCount: Int
    var supportLengthMicrometres: Double
    var rmseMicrometres: Double
    var usableForNavigation: Bool
}

struct BlindTrackReviewPreview: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var reviewedTrackSetSha256: String
    var reviewStateSha256: String
    var tracks: [BlindObservedTrackPreview]
    var unassignedSourcePointIDs: [String]
    var usableForNavigation: Bool

    var asEditableState: BlindTrackReviewState {
        BlindTrackReviewState(
            groups: tracks.map {
                BlindTrackReviewGroup(
                    groupId: $0.groupId,
                    sourcePointIDs: $0.sourcePointIDs.sorted()
                )
            }.sorted { $0.groupId < $1.groupId },
            unassignedSourcePointIDs: unassignedSourcePointIDs.sorted()
        )
    }

    var passesRetrospectiveBoundary: Bool {
        guard schemaVersion == 1,
              usableForNavigation == false,
              tracks.count <= 128,
              Self.isSHA256(reviewedTrackSetSha256),
              Self.isSHA256(reviewStateSha256),
              Set(tracks.map(\.trackId)).count == tracks.count,
              Set(tracks.map(\.groupId)).count == tracks.count,
              Set(unassignedSourcePointIDs).count == unassignedSourcePointIDs.count,
              unassignedSourcePointIDs.allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        var seenSourcePointIDs = Set(unassignedSourcePointIDs)
        for track in tracks {
            guard track.usableForNavigation == false,
                  !track.groupId.isEmpty,
                  track.groupId.count <= 200,
                  !track.trackId.isEmpty,
                  Self.isSHA256(track.fitDigest),
                  track.pointCount >= 3,
                  track.distinctSliceCount >= 2,
                  track.sourcePointIDs.count == track.pointCount,
                  Set(track.sourcePointIDs).count == track.sourcePointIDs.count,
                  track.sourcePointIDs.allSatisfy({ !$0.isEmpty }),
                  track.supportLengthMicrometres.isFinite,
                  track.supportLengthMicrometres > 0,
                  track.rmseMicrometres.isFinite,
                  track.rmseMicrometres >= 0 else {
                return false
            }
            for sourcePointID in track.sourcePointIDs {
                guard seenSourcePointIDs.insert(sourcePointID).inserted else {
                    return false
                }
            }
        }
        return true
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0))
        }
    }
}

enum BlindTrackReviewEditError: Error, Equatable, LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let detail): detail
        }
    }
}

enum BlindTrackReviewEditor {
    static func split(
        preview: BlindTrackReviewPreview,
        trackID: String,
        selectedSourcePointIDs: Set<String>
    ) throws -> BlindTrackReviewState {
        guard let track = preview.tracks.first(where: { $0.trackId == trackID }) else {
            throw BlindTrackReviewEditError.invalid("Select one available blind track to split.")
        }
        let source = Set(track.sourcePointIDs)
        guard !selectedSourcePointIDs.isEmpty,
              selectedSourcePointIDs.isSubset(of: source),
              selectedSourcePointIDs.count >= 3,
              source.subtracting(selectedSourcePointIDs).count >= 3 else {
            throw BlindTrackReviewEditError.invalid(
                "A split must leave at least three source points in each blind track."
            )
        }
        var state = preview.asEditableState
        guard let index = state.groups.firstIndex(where: { $0.groupId == track.groupId }) else {
            throw BlindTrackReviewEditError.invalid("Blind preview membership is inconsistent.")
        }
        let remainder = source.subtracting(selectedSourcePointIDs).sorted()
        state.groups[index].sourcePointIDs = remainder
        state.groups.append(
            BlindTrackReviewGroup(
                groupId: "manual-split-\(UUID().uuidString.lowercased())",
                sourcePointIDs: selectedSourcePointIDs.sorted()
            )
        )
        state.groups.sort { $0.groupId < $1.groupId }
        return state
    }

    static func merge(
        preview: BlindTrackReviewPreview,
        trackIDs: Set<String>
    ) throws -> BlindTrackReviewState {
        let tracks = preview.tracks.filter { trackIDs.contains($0.trackId) }
        guard tracks.count >= 2, tracks.count == trackIDs.count else {
            throw BlindTrackReviewEditError.invalid("Select at least two available blind tracks to merge.")
        }
        let groupIDs = Set(tracks.map(\.groupId))
        let points = Set(tracks.flatMap(\.sourcePointIDs))
        var state = preview.asEditableState
        state.groups.removeAll { groupIDs.contains($0.groupId) }
        state.groups.append(
            BlindTrackReviewGroup(
                groupId: "manual-merge-\(UUID().uuidString.lowercased())",
                sourcePointIDs: points.sorted()
            )
        )
        state.groups.sort { $0.groupId < $1.groupId }
        return state
    }

    static func reassign(
        preview: BlindTrackReviewPreview,
        sourcePointIDs: Set<String>,
        targetTrackID: String?
    ) throws -> BlindTrackReviewState {
        guard !sourcePointIDs.isEmpty else {
            throw BlindTrackReviewEditError.invalid("Select one or more source point IDs to reassign.")
        }
        let known = Set(preview.tracks.flatMap(\.sourcePointIDs))
            .union(preview.unassignedSourcePointIDs)
        guard sourcePointIDs.isSubset(of: known) else {
            throw BlindTrackReviewEditError.invalid("A selected source point is unavailable.")
        }
        var state = preview.asEditableState
        for index in state.groups.indices {
            state.groups[index].sourcePointIDs.removeAll { sourcePointIDs.contains($0) }
        }
        state.unassignedSourcePointIDs.removeAll { sourcePointIDs.contains($0) }
        if let targetTrackID {
            guard let target = preview.tracks.first(where: { $0.trackId == targetTrackID }),
                  let targetIndex = state.groups.firstIndex(where: { $0.groupId == target.groupId }) else {
                throw BlindTrackReviewEditError.invalid("Choose an available destination blind track.")
            }
            state.groups[targetIndex].sourcePointIDs = Array(
                Set(state.groups[targetIndex].sourcePointIDs).union(sourcePointIDs)
            ).sorted()
        } else {
            state.unassignedSourcePointIDs = Array(
                Set(state.unassignedSourcePointIDs).union(sourcePointIDs)
            ).sorted()
        }
        guard state.groups.allSatisfy({ $0.sourcePointIDs.count >= 3 }) else {
            throw BlindTrackReviewEditError.invalid(
                "Reassignment must leave at least three source points in every blind track."
            )
        }
        return state
    }
}
