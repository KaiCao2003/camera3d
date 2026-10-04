import Foundation

struct RegistrationCorrection: Codable, Equatable, Sendable {
    var atlasAPMicrons: Double
    var pitchDegrees: Double
    // The worker's correction interface calls the left/right plane tilt yaw;
    // existing QuickNII pose records store that angle as rollDegrees.
    var yawDegrees: Double
    var landmarks: [ManualLandmarkPair] = []

    init(pose: SlicePose) {
        atlasAPMicrons = pose.atlasAPMicrons
        pitchDegrees = pose.atlasSlicingAngles.pitchDegrees
        yawDegrees = pose.atlasSlicingAngles.rollDegrees
    }

    var hasValidPlane: Bool {
        atlasAPMicrons.isFinite && (0...13_200).contains(atlasAPMicrons)
            && pitchDegrees.isFinite && abs(pitchDegrees) < 80
            && yawDegrees.isFinite && abs(yawDegrees) < 80
    }

    func matchesPlane(_ pose: SlicePose) -> Bool {
        abs(atlasAPMicrons - pose.atlasAPMicrons) <= 1e-6
            && abs(pitchDegrees - pose.atlasSlicingAngles.pitchDegrees) <= 1e-6
            && abs(yawDegrees - pose.atlasSlicingAngles.rollDegrees) <= 1e-6
    }

    var hasUsableLandmarks: Bool {
        landmarks.count >= 3
            && Self.spansPlane(landmarks.map(\.atlasPoint))
            && Self.spansPlane(landmarks.map(\.slicePoint))
    }

    private static func spansPlane(_ points: [RegistrationPoint]) -> Bool {
        guard let origin = points.first,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        // A full 2D affine cannot be determined from collinear landmarks.
        for first in points.dropFirst() {
            for second in points.dropFirst() {
                let area = (first.x - origin.x) * (second.y - origin.y)
                    - (first.y - origin.y) * (second.x - origin.x)
                if abs(area) > 1e-3 { return true }
            }
        }
        return false
    }
}
