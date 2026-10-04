import AppKit
import CoreGraphics
import Foundation
import simd

struct TissueSurfaceMesh {
    var vertices: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var triangleIndices: [UInt32]
    var ringVertexCount: Int

    var triangleCount: Int { triangleIndices.count / 3 }
}

/// Builds a closed surface from the actual alpha silhouette of each section.
/// Every observed section remains a hard geometric constraint: rings are traced
/// from the ordered outer boundary, uniformly resampled, and only cyclically
/// re-indexed to establish correspondence with the neighboring section.
enum TissueSurfaceMeshBuilder {
    static func build(
        slices: [VolumeSlice],
        samplesPerRing: Int = 96,
        alphaThreshold: UInt8 = 20
    ) -> TissueSurfaceMesh? {
        let sampleCount = max(24, samplesPerRing)
        let orderedSlices = slices.sorted { $0.z < $1.z }
        guard orderedSlices.count >= 2 else {
            return nil
        }

        let sampledRings = orderedSlices.compactMap {
            contourRing(for: $0, sampleCount: sampleCount, alphaThreshold: alphaThreshold)
        }
        guard sampledRings.count >= 2 else {
            return nil
        }

        var rings = [sampledRings[0]]
        rings.reserveCapacity(sampledRings.count)
        for ring in sampledRings.dropFirst() {
            rings.append(phaseAligned(ring, to: rings[rings.count - 1]))
        }

        let vertices = rings.flatMap(\.points)
        var indices: [UInt32] = []
        indices.reserveCapacity((rings.count - 1) * sampleCount * 6 + (sampleCount - 2) * 6)

        for ringIndex in 0..<(rings.count - 1) {
            let currentStart = ringIndex * sampleCount
            let nextStart = (ringIndex + 1) * sampleCount
            for pointIndex in 0..<sampleCount {
                let nextPoint = (pointIndex + 1) % sampleCount
                let a = UInt32(currentStart + pointIndex)
                let b = UInt32(currentStart + nextPoint)
                let c = UInt32(nextStart + nextPoint)
                let d = UInt32(nextStart + pointIndex)
                indices.append(contentsOf: [a, b, c, a, c, d])
            }
        }

        guard let firstCap = triangulate(rings[0].points),
              let lastCap = triangulate(rings[rings.count - 1].points) else {
            return nil
        }
        let lastRingStart = (rings.count - 1) * sampleCount

        // The sampled rings are counter-clockwise in scene XY. Reverse the
        // first cap for the outward -Z normal and retain winding on the +Z cap.
        for triangle in firstCap {
            indices.append(contentsOf: [
                UInt32(triangle.0),
                UInt32(triangle.2),
                UInt32(triangle.1)
            ])
        }
        for triangle in lastCap {
            indices.append(contentsOf: [
                UInt32(lastRingStart + triangle.0),
                UInt32(lastRingStart + triangle.1),
                UInt32(lastRingStart + triangle.2)
            ])
        }

        return TissueSurfaceMesh(
            vertices: vertices,
            normals: vertexNormals(vertices: vertices, indices: indices),
            triangleIndices: indices,
            ringVertexCount: sampleCount
        )
    }

    /// Exposes the measured ring to geometry regressions without changing the
    /// production `build` API. The returned coordinates are never smoothed.
    static func sampledContourPoints(
        for slice: VolumeSlice,
        samplesPerRing: Int = 96,
        alphaThreshold: UInt8 = 20
    ) -> [SIMD3<Float>]? {
        contourRing(
            for: slice,
            sampleCount: max(24, samplesPerRing),
            alphaThreshold: alphaThreshold
        )?.points
    }

    private struct ContourRing {
        var points: [SIMD3<Float>]
    }

    private struct GridPoint: Hashable {
        var x: Int
        var y: Int
    }

    private struct BoundaryEdge: Hashable {
        var start: GridPoint
        var end: GridPoint
    }

    private static func contourRing(
        for slice: VolumeSlice,
        sampleCount: Int,
        alphaThreshold: UInt8
    ) -> ContourRing? {
        guard let raster = alphaRaster(from: slice.texture), raster.width > 1, raster.height > 1 else {
            return nil
        }

        guard let component = largestForegroundComponent(
            in: raster,
            alphaThreshold: alphaThreshold
        ),
        let boundary = orderedOuterBoundary(
            component: component,
            width: raster.width,
            height: raster.height
        ) else {
            return nil
        }

        var sceneBoundary = boundary.compactMap { point -> SIMD3<Float>? in
            if let placement = slice.atlasPlacement {
                return placement.scenePoint(
                    pixelX: Double(point.x),
                    pixelY: Double(point.y)
                )
            }
            return SIMD3<Float>(
                Float(
                    (Double(point.x) / Double(raster.width) - 0.5) * slice.width
                        + slice.offsetX
                ),
                Float(
                    (0.5 - Double(point.y) / Double(raster.height)) * slice.height
                        + slice.offsetY
                ),
                Float(slice.z)
            )
        }
        guard sceneBoundary.count >= 3 else {
            return nil
        }

        if signedArea(of: sceneBoundary) < 0 {
            sceneBoundary.reverse()
        }
        sceneBoundary = rotateToStableAnchor(sceneBoundary)

        guard let points = uniformlyResampled(sceneBoundary, count: sampleCount) else {
            return nil
        }
        return ContourRing(points: points)
    }

    private static func largestForegroundComponent(
        in raster: AlphaRaster,
        alphaThreshold: UInt8
    ) -> [Bool]? {
        let pixelCount = raster.width * raster.height
        var visited = [Bool](repeating: false, count: pixelCount)
        var largest: [Int] = []

        for start in 0..<pixelCount where !visited[start] && raster.alpha[start] > alphaThreshold {
            visited[start] = true
            var stack = [start]
            var component: [Int] = []

            while let index = stack.popLast() {
                component.append(index)
                let x = index % raster.width
                let y = index / raster.width
                if x > 0 {
                    appendForeground(
                        index - 1,
                        raster: raster,
                        alphaThreshold: alphaThreshold,
                        visited: &visited,
                        stack: &stack
                    )
                }
                if x + 1 < raster.width {
                    appendForeground(
                        index + 1,
                        raster: raster,
                        alphaThreshold: alphaThreshold,
                        visited: &visited,
                        stack: &stack
                    )
                }
                if y > 0 {
                    appendForeground(
                        index - raster.width,
                        raster: raster,
                        alphaThreshold: alphaThreshold,
                        visited: &visited,
                        stack: &stack
                    )
                }
                if y + 1 < raster.height {
                    appendForeground(
                        index + raster.width,
                        raster: raster,
                        alphaThreshold: alphaThreshold,
                        visited: &visited,
                        stack: &stack
                    )
                }
            }
            if component.count > largest.count {
                largest = component
            }
        }

        guard largest.count >= 4 else { return nil }
        var mask = [Bool](repeating: false, count: pixelCount)
        for index in largest {
            mask[index] = true
        }
        return mask
    }

    private static func appendForeground(
        _ index: Int,
        raster: AlphaRaster,
        alphaThreshold: UInt8,
        visited: inout [Bool],
        stack: inout [Int]
    ) {
        guard !visited[index], raster.alpha[index] > alphaThreshold else { return }
        visited[index] = true
        stack.append(index)
    }

    private static func orderedOuterBoundary(
        component: [Bool],
        width: Int,
        height: Int
    ) -> [GridPoint]? {
        var edges = Set<BoundaryEdge>()
        var outgoing: [GridPoint: [BoundaryEdge]] = [:]

        func isForeground(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < width && y >= 0 && y < height && component[y * width + x]
        }
        func addEdge(_ start: GridPoint, _ end: GridPoint) {
            let edge = BoundaryEdge(start: start, end: end)
            edges.insert(edge)
            outgoing[start, default: []].append(edge)
        }

        for y in 0..<height {
            for x in 0..<width where isForeground(x, y) {
                if !isForeground(x, y - 1) {
                    addEdge(GridPoint(x: x, y: y), GridPoint(x: x + 1, y: y))
                }
                if !isForeground(x + 1, y) {
                    addEdge(GridPoint(x: x + 1, y: y), GridPoint(x: x + 1, y: y + 1))
                }
                if !isForeground(x, y + 1) {
                    addEdge(GridPoint(x: x + 1, y: y + 1), GridPoint(x: x, y: y + 1))
                }
                if !isForeground(x - 1, y) {
                    addEdge(GridPoint(x: x, y: y + 1), GridPoint(x: x, y: y))
                }
            }
        }

        var unused = edges
        var loops: [[GridPoint]] = []
        while let seed = unused.first {
            var loop = [seed.start]
            var edge = seed
            unused.remove(edge)
            var isClosed = false

            for _ in 0...edges.count {
                loop.append(edge.end)
                if edge.end == seed.start {
                    isClosed = true
                    break
                }
                let candidates = (outgoing[edge.end] ?? []).filter { unused.contains($0) }
                guard let next = nextBoundaryEdge(after: edge, candidates: candidates) else {
                    break
                }
                edge = next
                unused.remove(next)
            }

            if isClosed {
                loop.removeLast()
                let simplified = removingCollinearPoints(loop)
                if simplified.count >= 3 {
                    loops.append(simplified)
                }
            }
        }

        return loops.max { abs(gridArea($0)) < abs(gridArea($1)) }
    }

    private static func nextBoundaryEdge(
        after edge: BoundaryEdge,
        candidates: [BoundaryEdge]
    ) -> BoundaryEdge? {
        let incoming = gridDirection(from: edge.start, to: edge.end)
        return candidates.min { lhs, rhs in
            turnRank(from: incoming, to: gridDirection(from: lhs.start, to: lhs.end))
                < turnRank(from: incoming, to: gridDirection(from: rhs.start, to: rhs.end))
        }
    }

    /// Directions increase clockwise in raster coordinates: east, south, west, north.
    private static func gridDirection(from start: GridPoint, to end: GridPoint) -> Int {
        switch (end.x - start.x, end.y - start.y) {
        case (1, 0): 0
        case (0, 1): 1
        case (-1, 0): 2
        default: 3
        }
    }

    private static func turnRank(from incoming: Int, to outgoing: Int) -> Int {
        switch (outgoing - incoming + 4) % 4 {
        case 1: 0 // right
        case 0: 1 // straight
        case 3: 2 // left
        default: 3 // reverse
        }
    }

    private static func removingCollinearPoints(_ points: [GridPoint]) -> [GridPoint] {
        guard points.count > 3 else { return points }
        return points.indices.compactMap { index in
            let previous = points[(index - 1 + points.count) % points.count]
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let cross = (current.x - previous.x) * (next.y - current.y)
                - (current.y - previous.y) * (next.x - current.x)
            return cross == 0 ? nil : current
        }
    }

    private static func gridArea(_ points: [GridPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        return points.indices.reduce(0.0) { partial, index in
            let current = points[index]
            let next = points[(index + 1) % points.count]
            return partial + Double(current.x * next.y - next.x * current.y)
        } / 2
    }

    private static func signedArea(of points: [SIMD3<Float>]) -> Double {
        guard points.count >= 3 else { return 0 }
        return points.indices.reduce(0.0) { partial, index in
            let current = points[index]
            let next = points[(index + 1) % points.count]
            return partial + Double(current.x * next.y - next.x * current.y)
        } / 2
    }

    private static func rotateToStableAnchor(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard !points.isEmpty else { return points }
        let meanY = points.map { Double($0.y) }.reduce(0, +) / Double(points.count)
        let anchor = points.indices.max { lhs, rhs in
            let left = points[lhs]
            let right = points[rhs]
            if abs(left.x - right.x) > 0.000_001 {
                return left.x < right.x
            }
            return abs(Double(left.y) - meanY) > abs(Double(right.y) - meanY)
        } ?? 0
        return Array(points[anchor...]) + Array(points[..<anchor])
    }

    private static func uniformlyResampled(
        _ points: [SIMD3<Float>],
        count: Int
    ) -> [SIMD3<Float>]? {
        guard points.count >= 3, count >= 3 else { return nil }
        let lengths = points.indices.map { index -> Double in
            let delta = points[(index + 1) % points.count] - points[index]
            return Double(simd_length(delta))
        }
        let perimeter = lengths.reduce(0, +)
        guard perimeter.isFinite, perimeter > 0.000_001 else { return nil }

        var result: [SIMD3<Float>] = []
        result.reserveCapacity(count)
        var segmentIndex = 0
        var segmentStartDistance = 0.0

        for sampleIndex in 0..<count {
            let target = Double(sampleIndex) * perimeter / Double(count)
            while segmentIndex + 1 < points.count,
                  segmentStartDistance + lengths[segmentIndex] < target {
                segmentStartDistance += lengths[segmentIndex]
                segmentIndex += 1
            }
            let length = max(0.000_000_1, lengths[segmentIndex])
            let fraction = Float((target - segmentStartDistance) / length)
            let start = points[segmentIndex]
            let end = points[(segmentIndex + 1) % points.count]
            result.append(start + (end - start) * fraction)
        }
        return result
    }

    private static func phaseAligned(_ ring: ContourRing, to reference: ContourRing) -> ContourRing {
        guard ring.points.count == reference.points.count, !ring.points.isEmpty else { return ring }
        let currentCenter = meanXY(ring.points)
        let referenceCenter = meanXY(reference.points)
        let currentScale = rmsRadius(ring.points, center: currentCenter)
        let referenceScale = rmsRadius(reference.points, center: referenceCenter)
        var bestShift = 0
        var bestCost = Double.infinity

        for shift in ring.points.indices {
            var cost = 0.0
            for index in reference.points.indices {
                let current = ring.points[(index + shift) % ring.points.count]
                let target = reference.points[index]
                let dx = (Double(current.x) - currentCenter.x) / currentScale
                    - (Double(target.x) - referenceCenter.x) / referenceScale
                let dy = (Double(current.y) - currentCenter.y) / currentScale
                    - (Double(target.y) - referenceCenter.y) / referenceScale
                cost += dx * dx + dy * dy
            }
            if cost < bestCost {
                bestCost = cost
                bestShift = shift
            }
        }

        var output = ring
        output.points = ring.points.indices.map { index in
            ring.points[(index + bestShift) % ring.points.count]
        }
        return output
    }

    private static func meanXY(_ points: [SIMD3<Float>]) -> (x: Double, y: Double) {
        let total = points.reduce((x: 0.0, y: 0.0)) { partial, point in
            (partial.x + Double(point.x), partial.y + Double(point.y))
        }
        return (total.x / Double(points.count), total.y / Double(points.count))
    }

    private static func rmsRadius(
        _ points: [SIMD3<Float>],
        center: (x: Double, y: Double)
    ) -> Double {
        let squared = points.reduce(0.0) { partial, point in
            let dx = Double(point.x) - center.x
            let dy = Double(point.y) - center.y
            return partial + dx * dx + dy * dy
        }
        return max(0.000_001, sqrt(squared / Double(points.count)))
    }

    private static func triangulate(
        _ points: [SIMD3<Float>]
    ) -> [(Int, Int, Int)]? {
        guard points.count >= 3, signedArea(of: points) > 0 else { return nil }
        var polygon = Array(points.indices)
        var triangles: [(Int, Int, Int)] = []
        triangles.reserveCapacity(points.count - 2)
        let epsilon = 1e-10

        while polygon.count > 3 {
            var foundEar = false
            for position in polygon.indices {
                let previous = polygon[(position - 1 + polygon.count) % polygon.count]
                let current = polygon[position]
                let next = polygon[(position + 1) % polygon.count]
                guard cross(points[previous], points[current], points[next]) > epsilon else {
                    continue
                }
                let containsPoint = polygon.contains { candidate in
                    guard candidate != previous, candidate != current, candidate != next else {
                        return false
                    }
                    return isStrictlyInsideTriangle(
                        points[candidate],
                        points[previous],
                        points[current],
                        points[next],
                        epsilon: epsilon
                    )
                }
                guard !containsPoint else { continue }
                triangles.append((previous, current, next))
                polygon.remove(at: position)
                foundEar = true
                break
            }
            guard foundEar else { return nil }
        }

        guard polygon.count == 3,
              cross(points[polygon[0]], points[polygon[1]], points[polygon[2]]) > epsilon else {
            return nil
        }
        triangles.append((polygon[0], polygon[1], polygon[2]))
        return triangles
    }

    private static func cross(
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>
    ) -> Double {
        Double(b.x - a.x) * Double(c.y - a.y)
            - Double(b.y - a.y) * Double(c.x - a.x)
    }

    private static func isStrictlyInsideTriangle(
        _ point: SIMD3<Float>,
        _ a: SIMD3<Float>,
        _ b: SIMD3<Float>,
        _ c: SIMD3<Float>,
        epsilon: Double
    ) -> Bool {
        cross(a, b, point) > epsilon
            && cross(b, c, point) > epsilon
            && cross(c, a, point) > epsilon
    }

    private static func vertexNormals(
        vertices: [SIMD3<Float>],
        indices: [UInt32]
    ) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for triangleStart in stride(from: 0, to: indices.count, by: 3) {
            let ia = Int(indices[triangleStart])
            let ib = Int(indices[triangleStart + 1])
            let ic = Int(indices[triangleStart + 2])
            let faceNormal = simd_cross(vertices[ib] - vertices[ia], vertices[ic] - vertices[ia])
            guard faceNormal.x.isFinite, faceNormal.y.isFinite, faceNormal.z.isFinite else {
                continue
            }
            normals[ia] += faceNormal
            normals[ib] += faceNormal
            normals[ic] += faceNormal
        }
        return normals.map { normal in
            let length = simd_length(normal)
            return length > 0.000_001 ? normal / length : SIMD3<Float>(0, 1, 0)
        }
    }

    private struct AlphaRaster {
        var width: Int
        var height: Int
        var alpha: [UInt8]
    }

    private static func alphaRaster(from image: NSImage) -> AlphaRaster? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil) else {
            return nil
        }
        let width = cgImage.width
        let height = cgImage.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return AlphaRaster(
            width: width,
            height: height,
            alpha: stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
        )
    }
}
