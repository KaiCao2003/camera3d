import Foundation

extension BinaryFloatingPoint {
    var clampedUnit: Self {
        min(1, max(0, self))
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
