import Foundation

struct AtlasRegionInteractionContext: Hashable, Sendable {
    var sliceID: String
    var annotationPath: String?
    var structuresPath: String
    /// Re-registration overwrites the annotation artifact at the same path.
    /// Including the transform revision prevents a stale label raster or pin
    /// from surviving that scientifically meaningful content change.
    var registrationRevision: Date?
}

struct AtlasRegionInteractionState: Equatable, Sendable {
    private(set) var context: AtlasRegionInteractionContext?
    private(set) var hoveredRegion: AtlasRegionHit?
    private(set) var pinnedRegion: AtlasRegionHit?

    var displayedRegion: AtlasRegionHit? {
        hoveredRegion ?? pinnedRegion
    }

    var isDisplayingPreview: Bool {
        hoveredRegion != nil && hoveredRegion != pinnedRegion
    }

    @discardableResult
    mutating func synchronize(to newContext: AtlasRegionInteractionContext) -> Bool {
        guard context != newContext else { return false }
        context = newContext
        hoveredRegion = nil
        pinnedRegion = nil
        return true
    }

    mutating func updateHover(_ region: AtlasRegionHit?) {
        hoveredRegion = region
    }

    mutating func setDirectLookupEnabled(_ isEnabled: Bool) {
        if !isEnabled {
            hoveredRegion = nil
        }
    }

    mutating func pin(_ region: AtlasRegionHit?) {
        guard let region else { return }
        pinnedRegion = region
        hoveredRegion = nil
    }

    mutating func clearPin() {
        pinnedRegion = nil
    }
}
