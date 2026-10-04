import AppKit
import Foundation
import simd

/// Independent presentation switches for post-lock retrospective layers.
/// The values never grant access to prior data; the snapshot boundary below
/// returns no payload until blind review is locked.
struct Brain3DRetrospectiveOverlayVisibility: Hashable, Sendable {
    var showsPlannedShanks = true
    var showsObservedEvidence = true
    var showsAllenROIMask = false
    var showsASRBoxes = false
}

struct Brain3DLockedAllenROI: Identifiable, Hashable, Sendable {
    var id: String { "\(roiSetID)::allen::\(structureID)::\(includeDescendants)" }
    var roiSetID: String
    var roiSetName: String
    var structureID: Int
    var includeDescendants: Bool
}

struct Brain3DLockedASRBoxROI: Identifiable, Hashable, Sendable {
    var id: String { "\(roiSetID)::box::\(boxID)" }
    var roiSetID: String
    var roiSetName: String
    var boxID: String
    var minimumASRMicrometres: SIMD3<Double>
    var maximumASRMicrometres: SIMD3<Double>
}

/// A fail-closed, compact payload for rendering only after blind review lock.
/// Observed supports retain their worker-defined A/B endpoint names and remain
/// explicitly retrospective evidence, never navigation data.
struct Brain3DRetrospectiveOverlaySnapshot: Hashable, Sendable {
    var plannedShanks: [Brain3DPlannedShankReview]
    var observedTracks: [Brain3DObservedTrackReview]
    var allenROIs: [Brain3DLockedAllenROI]
    var asrBoxes: [Brain3DLockedASRBoxROI]
    var usableForNavigation: Bool

    static func locked(context: Brain3DContext?) -> Brain3DRetrospectiveOverlaySnapshot? {
        guard let context,
              context.blindReviewLocked,
              let preview = context.reviewPreview,
              preview.schemaVersion == 1,
              preview.usableForNavigation == false,
              preview.plannedShanks.allSatisfy({ $0.usableForNavigation == false }),
              preview.tracks.allSatisfy({ $0.usableForNavigation == false }),
              preview.plannedShanks.allSatisfy({ shank in
                  guard let first = shank.entry.strictASRVector,
                        let second = shank.tip.strictASRVector else { return false }
                  return simd_length(second - first).isFinite
                      && simd_length(second - first) > 1e-9
              }),
              preview.tracks.allSatisfy({ track in
                  guard let first = track.endpointA.strictASRVector,
                        let second = track.endpointB.strictASRVector else { return false }
                  return simd_length(second - first).isFinite
                      && simd_length(second - first) > 1e-9
                      && track.supportLengthMicrometres.isFinite
                      && track.supportLengthMicrometres > 0
                      && track.rmseMicrometres.isFinite
                      && track.rmseMicrometres >= 0
              }),
              context.handoff.raw["usable_for_navigation"]?.strictBoolValue == false,
              let lockedROIs = context.handoff.lockedRetrospectiveROIs else {
            return nil
        }

        return Brain3DRetrospectiveOverlaySnapshot(
            plannedShanks: preview.plannedShanks.sorted { $0.id < $1.id },
            observedTracks: preview.tracks.sorted { $0.trackId < $1.trackId },
            allenROIs: lockedROIs.allen.sorted { $0.id < $1.id },
            asrBoxes: lockedROIs.boxes.sorted { $0.id < $1.id },
            usableForNavigation: false
        )
    }
}

private struct Brain3DLockedRetrospectiveROIs {
    var allen: [Brain3DLockedAllenROI]
    var boxes: [Brain3DLockedASRBoxROI]
}

private extension Brain3DHistologyHandoff {
    var lockedRetrospectiveROIs: Brain3DLockedRetrospectiveROIs? {
        guard let values = raw["roi_sets"]?.arrayValue, !values.isEmpty else { return nil }
        var allen: [Brain3DLockedAllenROI] = []
        var boxes: [Brain3DLockedASRBoxROI] = []

        for value in values {
            guard let roiSet = value.objectValue,
                  let roiSetID = roiSet["roi_set_id"]?.stringValue,
                  !roiSetID.isEmpty,
                  let name = roiSet["name"]?.stringValue,
                  !name.isEmpty,
                  let allenValues = roiSet["allen_structures"]?.arrayValue,
                  let boxValues = roiSet["asr_boxes"]?.arrayValue,
                  !allenValues.isEmpty || !boxValues.isEmpty else {
                return nil
            }

            for member in allenValues {
                guard let object = member.objectValue,
                      let structureID = object["structure_id"]?.integerValue,
                      structureID > 0,
                      let includeDescendants = object["include_descendants"]?.strictBoolValue else {
                    return nil
                }
                allen.append(
                    Brain3DLockedAllenROI(
                        roiSetID: roiSetID,
                        roiSetName: name,
                        structureID: structureID,
                        includeDescendants: includeDescendants
                    )
                )
            }

            for member in boxValues {
                guard let object = member.objectValue,
                      let boxID = object["box_id"]?.stringValue,
                      !boxID.isEmpty,
                      let minimum = object["minimum"]?.strictASRPoint,
                      let maximum = object["maximum"]?.strictASRPoint,
                      minimum.x < maximum.x,
                      minimum.y < maximum.y,
                      minimum.z < maximum.z else {
                    return nil
                }
                boxes.append(
                    Brain3DLockedASRBoxROI(
                        roiSetID: roiSetID,
                        roiSetName: name,
                        boxID: boxID,
                        minimumASRMicrometres: minimum,
                        maximumASRMicrometres: maximum
                    )
                )
            }
        }
        return Brain3DLockedRetrospectiveROIs(allen: allen, boxes: boxes)
    }
}

private extension StrictJSONValue {
    var strictBoolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var strictDoubleValue: Double? {
        guard case .number(let value) = self, value.isFinite else { return nil }
        return value
    }

    var strictASRPoint: SIMD3<Double>? {
        if let values = arrayValue,
           values.count == 3,
           let ap = values[0].strictDoubleValue,
           let dv = values[1].strictDoubleValue,
           let ml = values[2].strictDoubleValue {
            return SIMD3<Double>(ap, dv, ml)
        }
        guard let object = objectValue,
              Set(object.keys) == ["ap_um", "dv_um", "ml_um"],
              let ap = object["ap_um"]?.strictDoubleValue,
              let dv = object["dv_um"]?.strictDoubleValue,
              let ml = object["ml_um"]?.strictDoubleValue else {
            return nil
        }
        return SIMD3<Double>(ap, dv, ml)
    }
}

enum Brain3DRetrospectiveSegmentKind: Hashable, Sendable {
    case plannedShank
    case observedEvidence
}

struct Brain3DRetrospectiveSegment: Identifiable, Hashable, Sendable {
    var id: String
    var endpointAASRMicrometres: SIMD3<Double>
    var endpointBASRMicrometres: SIMD3<Double>
    var kind: Brain3DRetrospectiveSegmentKind
}

extension Brain3DRetrospectiveOverlaySnapshot {
    var plannedSegments: [Brain3DRetrospectiveSegment] {
        plannedShanks.compactMap { shank in
            guard let first = shank.entry.strictASRVector,
                  let second = shank.tip.strictASRVector else { return nil }
            return Brain3DRetrospectiveSegment(
                id: shank.id,
                endpointAASRMicrometres: first,
                endpointBASRMicrometres: second,
                kind: .plannedShank
            )
        }
    }

    var observedSegments: [Brain3DRetrospectiveSegment] {
        observedTracks.compactMap { track in
            guard let endpointA = track.endpointA.strictASRVector,
                  let endpointB = track.endpointB.strictASRVector else { return nil }
            return Brain3DRetrospectiveSegment(
                id: track.trackId,
                endpointAASRMicrometres: endpointA,
                endpointBASRMicrometres: endpointB,
                kind: .observedEvidence
            )
        }
    }
}

private extension Array where Element == Double {
    var strictASRVector: SIMD3<Double>? {
        guard count == 3, allSatisfy(\.isFinite) else { return nil }
        return SIMD3<Double>(self[0], self[1], self[2])
    }
}

/// Deterministic projection helpers shared by the 2D canvas and focused tests.
/// Atlas points use physical BrainGlobe ASR micrometres throughout.
enum Brain3DRetrospectiveOverlayGeometry {
    static func atlasPlanePixel(
        for atlasPoint: SIMD3<Double>,
        placement: AtlasSlicePlacement
    ) -> CGPoint? {
        guard let basis = planeBasis(placement),
              placement.planeSize.width > 0,
              placement.planeSize.height > 0 else { return nil }
        let delta = atlasPoint - basis.origin
        let uu = simd_dot(basis.u, basis.u)
        let uv = simd_dot(basis.u, basis.v)
        let vv = simd_dot(basis.v, basis.v)
        let determinant = uu * vv - uv * uv
        guard determinant.isFinite, abs(determinant) > 1e-9 else { return nil }
        let du = simd_dot(delta, basis.u)
        let dv = simd_dot(delta, basis.v)
        let uFraction = (du * vv - dv * uv) / determinant
        let vFraction = (dv * uu - du * uv) / determinant
        guard uFraction.isFinite, vFraction.isFinite else { return nil }
        return CGPoint(
            x: uFraction * Double(placement.planeSize.width),
            y: vFraction * Double(placement.planeSize.height)
        )
    }

    /// Clips a finite segment to one atlas-voxel-thick slab centered on the
    /// accepted section, then projects that local support into review pixels.
    static func sliceSegment(
        _ segment: Brain3DRetrospectiveSegment,
        placement: AtlasSlicePlacement,
        slabHalfThicknessMicrometres: Double? = nil
    ) -> [CGPoint]? {
        guard let basis = planeBasis(placement) else { return nil }
        let halfThickness = slabHalfThicknessMicrometres
            ?? max(placement.atlasResolutionMicrons.x,
                   max(placement.atlasResolutionMicrons.y, placement.atlasResolutionMicrons.z)) / 2
        guard halfThickness.isFinite, halfThickness > 0 else { return nil }

        let start = segment.endpointAASRMicrometres
        let end = segment.endpointBASRMicrometres
        let normal = basis.normal
        let startDistance = simd_dot(start - basis.origin, normal)
        let endDistance = simd_dot(end - basis.origin, normal)
        guard let interval = slabInterval(
            startDistance: startDistance,
            endDistance: endDistance,
            halfThickness: halfThickness
        ) else { return nil }
        let delta = end - start
        guard let first = atlasPlanePixel(for: start + delta * interval.lowerBound, placement: placement),
              let second = atlasPlanePixel(for: start + delta * interval.upperBound, placement: placement),
              let clipped = clipLine(
                  from: first,
                  to: second,
                  rectangle: CGRect(
                      x: 0,
                      y: 0,
                      width: placement.planeSize.width,
                      height: placement.planeSize.height
                  )
              ) else { return nil }
        return [clipped.0, clipped.1]
    }

    /// Exact zero-thickness intersection between an ASR box and the accepted
    /// atlas plane. The returned polygon is ordered around its centroid.
    static func sliceBoxPolygon(
        _ box: Brain3DLockedASRBoxROI,
        placement: AtlasSlicePlacement
    ) -> [CGPoint] {
        guard let basis = planeBasis(placement) else { return [] }
        let minimum = box.minimumASRMicrometres
        let maximum = box.maximumASRMicrometres
        let vertices = boxVertices(minimum: minimum, maximum: maximum)
        let edges = boxEdgeIndices
        let epsilon = 1e-7
        var points: [SIMD3<Double>] = []

        for (firstIndex, secondIndex) in edges {
            let first = vertices[firstIndex]
            let second = vertices[secondIndex]
            let firstDistance = simd_dot(first - basis.origin, basis.normal)
            let secondDistance = simd_dot(second - basis.origin, basis.normal)
            if abs(firstDistance) <= epsilon {
                appendUnique(first, to: &points)
            }
            if abs(secondDistance) <= epsilon {
                appendUnique(second, to: &points)
            }
            if (firstDistance < -epsilon && secondDistance > epsilon)
                || (firstDistance > epsilon && secondDistance < -epsilon) {
                let amount = firstDistance / (firstDistance - secondDistance)
                appendUnique(first + (second - first) * amount, to: &points)
            }
        }

        let projected = points.compactMap { atlasPlanePixel(for: $0, placement: placement) }
        guard projected.count >= 3 else { return [] }
        let centroid = CGPoint(
            x: projected.map(\.x).reduce(0, +) / Double(projected.count),
            y: projected.map(\.y).reduce(0, +) / Double(projected.count)
        )
        return projected.sorted {
            atan2($0.y - centroid.y, $0.x - centroid.x)
                < atan2($1.y - centroid.y, $1.x - centroid.x)
        }
    }

    static func boxVertices(
        minimum: SIMD3<Double>,
        maximum: SIMD3<Double>
    ) -> [SIMD3<Double>] {
        [minimum.x, maximum.x].flatMap { ap in
            [minimum.y, maximum.y].flatMap { dv in
                [minimum.z, maximum.z].map { ml in SIMD3<Double>(ap, dv, ml) }
            }
        }
    }

    static let boxEdgeIndices: [(Int, Int)] = [
        (0, 1), (0, 2), (0, 4),
        (1, 3), (1, 5),
        (2, 3), (2, 6),
        (3, 7),
        (4, 5), (4, 6),
        (5, 7), (6, 7),
    ]

    private struct PlaneBasis {
        var origin: SIMD3<Double>
        var u: SIMD3<Double>
        var v: SIMD3<Double>
        var normal: SIMD3<Double>
    }

    private static func planeBasis(_ placement: AtlasSlicePlacement) -> PlaneBasis? {
        let resolution = placement.atlasResolutionMicrons
        let origin = placement.atlasOriginIndex * resolution
        let u = placement.atlasUIndex * resolution
        let v = placement.atlasVIndex * resolution
        let cross = simd_cross(u, v)
        let length = simd_length(cross)
        guard [origin.x, origin.y, origin.z, u.x, u.y, u.z, v.x, v.y, v.z, length]
            .allSatisfy(\.isFinite), length > 1e-9 else { return nil }
        return PlaneBasis(origin: origin, u: u, v: v, normal: cross / length)
    }

    private static func slabInterval(
        startDistance: Double,
        endDistance: Double,
        halfThickness: Double
    ) -> ClosedRange<Double>? {
        let delta = endDistance - startDistance
        if abs(delta) <= 1e-12 {
            return abs(startDistance) <= halfThickness ? 0...1 : nil
        }
        let first = (-halfThickness - startDistance) / delta
        let second = (halfThickness - startDistance) / delta
        let lower = max(0, min(first, second))
        let upper = min(1, max(first, second))
        return lower <= upper ? lower...upper : nil
    }

    private static func clipLine(
        from start: CGPoint,
        to end: CGPoint,
        rectangle: CGRect
    ) -> (CGPoint, CGPoint)? {
        let dx = end.x - start.x
        let dy = end.y - start.y
        var lower = 0.0
        var upper = 1.0
        let checks = [
            (-dx, start.x - rectangle.minX),
            (dx, rectangle.maxX - start.x),
            (-dy, start.y - rectangle.minY),
            (dy, rectangle.maxY - start.y),
        ]
        for (direction, distance) in checks {
            if abs(direction) <= 1e-12 {
                if distance < 0 { return nil }
                continue
            }
            let amount = distance / direction
            if direction < 0 {
                lower = max(lower, amount)
            } else {
                upper = min(upper, amount)
            }
            if lower > upper { return nil }
        }
        return (
            CGPoint(x: start.x + lower * dx, y: start.y + lower * dy),
            CGPoint(x: start.x + upper * dx, y: start.y + upper * dy)
        )
    }

    private static func appendUnique(
        _ point: SIMD3<Double>,
        to points: inout [SIMD3<Double>]
    ) {
        guard !points.contains(where: { simd_length($0 - point) <= 1e-6 }) else { return }
        points.append(point)
    }
}

/// Exact membership raster derived from the accepted section's uint32 Allen
/// annotation artifact. It is presentation-only and remains separate from all
/// registration and reconstruction inputs.
struct Brain3DAllenROIMaskRaster: Hashable, Sendable {
    var width: Int
    var height: Int
    var alpha: [UInt8]

    var includedPixelCount: Int { alpha.reduce(0) { $0 + ($1 == 0 ? 0 : 1) } }

    func contains(x: Int, y: Int) -> Bool {
        guard (0..<width).contains(x), (0..<height).contains(y) else { return false }
        return alpha[y * width + x] != 0
    }

    func image(color: NSColor = .systemTeal) -> NSImage? {
        guard width > 0, height > 0, alpha.count == width * height,
              let rgb = color.usingColorSpace(.deviceRGB) else { return nil }
        let red = UInt8((rgb.redComponent * 255).rounded())
        let green = UInt8((rgb.greenComponent * 255).rounded())
        let blue = UInt8((rgb.blueComponent * 255).rounded())
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in alpha.indices where alpha[index] != 0 {
            let opacity = UInt16(alpha[index])
            rgba[index * 4] = UInt8(UInt16(red) * opacity / 255)
            rgba[index * 4 + 1] = UInt8(UInt16(green) * opacity / 255)
            rgba[index * 4 + 2] = UInt8(UInt16(blue) * opacity / 255)
            rgba[index * 4 + 3] = UInt8(opacity)
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
}

extension AtlasRegionLookup {
    func retrospectiveROIMask(
        for members: [Brain3DLockedAllenROI]
    ) -> Brain3DAllenROIMaskRaster {
        guard !members.isEmpty else {
            return Brain3DAllenROIMaskRaster(
                width: annotation.width,
                height: annotation.height,
                alpha: [UInt8](repeating: 0, count: annotation.width * annotation.height)
            )
        }
        var matchCache: [UInt32: Bool] = [:]
        var alpha = [UInt8](repeating: 0, count: annotation.width * annotation.height)
        for y in 0..<annotation.height {
            for x in 0..<annotation.width {
                guard let label = annotation.structureID(x: x, y: y), label != 0 else { continue }
                let matches = matchCache[label] ?? {
                    let value = members.contains { member in
                        guard UInt32(exactly: member.structureID) != nil else { return false }
                        if label == UInt32(member.structureID) { return true }
                        guard member.includeDescendants,
                              let structure = catalog.structure(for: label) else { return false }
                        return structure.structureIDPath.contains(member.structureID)
                    }
                    matchCache[label] = value
                    return value
                }()
                if matches { alpha[y * annotation.width + x] = 72 }
            }
        }
        return Brain3DAllenROIMaskRaster(
            width: annotation.width,
            height: annotation.height,
            alpha: alpha
        )
    }
}
