import AppKit
import SwiftUI

enum BrainBuilderTheme {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let sceneBackgroundColor = Color.white
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let surfaceRaised = Color(nsColor: .selectedContentBackgroundColor).opacity(0.12)
    static let surfaceSoft = Color.primary.opacity(0.035)
    static let border = Color(nsColor: .separatorColor)
    static let borderStrong = Color.primary.opacity(0.18)
    static let accent = Color.accentColor
    static let mint = Color(nsColor: .systemGreen)
    static let amber = Color(nsColor: .systemOrange)
    static let rose = Color(nsColor: .systemRed)
    static let secondaryText = Color.secondary

    static let sceneBackground = NSColor.white
}

struct BrainBuilderPanelModifier: ViewModifier {
    var cornerRadius: CGFloat
    var fill: Color

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: min(cornerRadius, 6), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: min(cornerRadius, 6), style: .continuous)
                    .stroke(BrainBuilderTheme.border, lineWidth: 1)
            }
    }
}

extension View {
    func brainBuilderPanel(
        cornerRadius: CGFloat = 6,
        fill: Color = BrainBuilderTheme.surface
    ) -> some View {
        modifier(BrainBuilderPanelModifier(cornerRadius: cornerRadius, fill: fill))
    }
}

struct BrainBuilderSectionLabel: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(BrainBuilderTheme.secondaryText)
    }
}

struct BrainBuilderStatusDot: View {
    var color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .frame(width: 12, height: 12)
    }
}
