import Foundation

struct Brain3DLeaveOneSectionOutOmission: Codable, Hashable, Sendable {
    var omittedSliceId: String
    var retainedPointCount: Int
    var heldOutPointCount: Int
    var axisAngleDegrees: Double
    var lineSeparationMicrometres: Double
    var heldOutRMSEMicrometres: Double
}

struct Brain3DLeaveOneSectionOutSensitivity: Codable, Hashable, Sendable {
    var available: Bool
    var reason: String? = nil
    var method: String? = nil
    var omissionCount: Int? = nil
    var maximumAxisAngleDegrees: Double? = nil
    var maximumLineSeparationMicrometres: Double? = nil
    var rmsHeldOutResidualMicrometres: Double? = nil
    var omissions: [Brain3DLeaveOneSectionOutOmission]? = nil
    var usableForNavigation: Bool
}

/// Compact, post-lock blind reconstruction support presented for manual review.
/// Endpoint A/B deliberately remain undirected finite evidence endpoints.
struct Brain3DObservedTrackReview: Codable, Identifiable, Hashable, Sendable {
    var id: String { trackId }
    var trackId: String
    var fitDigest: String
    var endpointA: [Double]
    var endpointB: [Double]
    var supportLengthMicrometres: Double
    var rmseMicrometres: Double
    var pointCount: Int
    var distinctSliceCount: Int
    var leaveOneSectionOutSensitivity: Brain3DLeaveOneSectionOutSensitivity
    var usableForNavigation: Bool
}

struct Brain3DPlannedShankReview: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(insertionSnapshotId)::\(shankId)" }
    var insertionSnapshotId: String
    var planId: String
    var shankId: String
    var entry: [Double]
    var tip: [Double]
    var usableForNavigation: Bool
}

struct Brain3DReviewSuggestion: Codable, Hashable, Sendable {
    var trackId: String
    var insertionSnapshotId: String
    var shankId: String?
    var state: String
    var reviewHeuristicCost: Double
    var requiresReviewerConfirmation: Bool
}

struct Brain3DROISideSummary: Codable, Hashable, Sendable {
    var segmentIds: [String]
    var traversedMemberKeys: [String]
    var totalTraversalLengthMicrometres: Double
}

struct Brain3DROISetMembershipSummary: Codable, Hashable, Sendable {
    var traversedMemberKeys: [String]
}

struct Brain3DROIMemberSummary: Codable, Hashable, Sendable {
    var memberKey: String
    var type: String
    var structureId: Int? = nil
    var includeDescendants: Bool? = nil
    var boxId: String? = nil
    var minimum: [Double]? = nil
    var maximum: [Double]? = nil
    var plannedSegmentIds: [String]
    var observedTrackIds: [String]
    var plannedTraversalLengthMicrometres: Double
    var observedTraversalLengthMicrometres: Double
}

struct Brain3DROISetReviewSummary: Codable, Identifiable, Hashable, Sendable {
    var id: String { roiSetId }
    var roiSetId: String
    var name: String
    var scope: String
    var insertionSnapshotIds: [String]
    var members: [Brain3DROIMemberSummary]
    var planned: Brain3DROISideSummary
    var observed: Brain3DROISideSummary
    var intersection: Brain3DROISetMembershipSummary
    var union: Brain3DROISetMembershipSummary
    var aggregation: String
    var usableForNavigation: Bool
}

struct Brain3DReviewPreview: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var reviewedTrackSetSha256: String
    var tracks: [Brain3DObservedTrackReview]
    var plannedShanks: [Brain3DPlannedShankReview]
    var suggestions: [Brain3DReviewSuggestion]
    var roiSummaries: [Brain3DROISetReviewSummary]
    var unassignedSourcePointIDs: [String]
    var usableForNavigation: Bool
}

extension Brain3DContext {
    /// Mirrors the worker's fail-closed export boundary so the UI can explain
    /// incomplete review before launching a worker process.
    var manualReviewBlockers: [String] {
        guard blindReviewLocked else {
            return ["Blind registration and track review must be locked before Brain3D comparison."]
        }
        guard let reviewPreview else {
            return ["Build the post-lock Brain3D matching review before export."]
        }
        guard reviewPreview.schemaVersion == 1,
              reviewPreview.usableForNavigation == false,
              reviewPreview.tracks.allSatisfy({ $0.usableForNavigation == false }),
              reviewPreview.tracks.allSatisfy({
                  $0.leaveOneSectionOutSensitivity.usableForNavigation == false
              }),
              reviewPreview.roiSummaries.allSatisfy({ $0.usableForNavigation == false }),
              reviewPreview.plannedShanks.allSatisfy({ $0.usableForNavigation == false }) else {
            return ["Brain3D review preview failed the retrospective-evidence boundary."]
        }

        let trackIDs = Set(reviewPreview.tracks.map(\.trackId))
        let shankKeys = Set(reviewPreview.plannedShanks.map(\.id))
        var observedCounts = Dictionary(uniqueKeysWithValues: trackIDs.map { ($0, 0) })
        var exactKeys = Set<String>()
        var missingKeys = Set<String>()
        var ambiguousInsertions = Set<String>()
        var invalid = false

        for disposition in reviewDispositions {
            if disposition.reviewerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || disposition.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                invalid = true
            }
            switch disposition.state {
            case .exactShank:
                guard let trackID = disposition.trackId,
                      let insertionID = disposition.insertionSnapshotId,
                      let shankID = disposition.shankId,
                      observedCounts[trackID] != nil else {
                    invalid = true
                    continue
                }
                observedCounts[trackID, default: 0] += 1
                let key = "\(insertionID)::\(shankID)"
                if !shankKeys.contains(key) || !exactKeys.insert(key).inserted {
                    invalid = true
                }
            case .insertionLevelAmbiguous:
                guard let trackID = disposition.trackId,
                      let insertionID = disposition.insertionSnapshotId,
                      disposition.shankId == nil,
                      observedCounts[trackID] != nil,
                      reviewPreview.plannedShanks.contains(where: {
                          $0.insertionSnapshotId == insertionID
                      }) else {
                    invalid = true
                    continue
                }
                observedCounts[trackID, default: 0] += 1
                ambiguousInsertions.insert(insertionID)
            case .observedUnmatched:
                guard let trackID = disposition.trackId,
                      disposition.insertionSnapshotId == nil,
                      disposition.shankId == nil,
                      observedCounts[trackID] != nil else {
                    invalid = true
                    continue
                }
                observedCounts[trackID, default: 0] += 1
            case .plannedNotObserved:
                guard disposition.trackId == nil,
                      let insertionID = disposition.insertionSnapshotId,
                      let shankID = disposition.shankId else {
                    invalid = true
                    continue
                }
                let key = "\(insertionID)::\(shankID)"
                if !shankKeys.contains(key) || !missingKeys.insert(key).inserted {
                    invalid = true
                }
            }
        }

        if invalid || observedCounts.values.contains(where: { $0 != 1 }) {
            return ["Every observed track needs one valid manual disposition with reviewer and reason."]
        }
        if !exactKeys.isDisjoint(with: missingKeys)
            || reviewPreview.plannedShanks.contains(where: {
                ambiguousInsertions.contains($0.insertionSnapshotId)
                    && missingKeys.contains($0.id)
            }) {
            return ["Brain3D review contains conflicting planned-shank dispositions."]
        }
        let ambiguousKeys = Set(
            reviewPreview.plannedShanks
                .filter { ambiguousInsertions.contains($0.insertionSnapshotId) }
                .map(\.id)
        )
        if exactKeys.union(missingKeys).union(ambiguousKeys) != shankKeys {
            return ["Every planned physical shank needs an exact, ambiguous, or not-observed disposition."]
        }
        return []
    }
}
