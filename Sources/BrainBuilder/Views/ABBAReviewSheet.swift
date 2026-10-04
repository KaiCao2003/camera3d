import AppKit
import SwiftUI

/// Official nonlinear results have their own source-pixel grid. This viewer
/// deliberately does not reuse the affine workspace's region or track lookup.
struct ABBAReviewSheet: View {
    let preview: ABBAReviewPreview
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var mode = Mode.borders
    @State private var opacity = 0.35
    @State private var zoom = 1.0

    private enum Mode: String, CaseIterable, Identifiable {
        case histology = "Histology"
        case atlas = "Atlas"
        case overlay = "Overlay"
        case borders = "Borders"
        var id: String { rawValue }
    }

    private var slice: ABBAReviewSlice? {
        preview.slices.first(where: { $0.id == selectedID }) ?? preview.slices.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Official ABBA · \(preview.stage.capitalized)")
                        .font(.title2.weight(.semibold))
                    Text("\(preview.slices.count) sections · source pixel grid · anatomical review required")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show files") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: preview.statePath)])
                }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 12) {
                List(preview.slices, selection: $selectedID) { section in
                    Text(section.title).tag(section.id).padding(.vertical, 4)
                }
                .frame(width: 185)
                .listStyle(.sidebar)
                VStack(spacing: 10) {
                    HStack {
                        Picker("View", selection: $mode) {
                            ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 400)
                        Spacer()
                        Button("Fit") { zoom = 1 }
                        Button("−") { zoom = max(1, zoom / 1.25) }
                            .disabled(zoom <= 1).accessibilityLabel("Zoom out ABBA result")
                        Text("\(Int(zoom * 100))%")
                            .font(.caption.monospacedDigit()).frame(width: 42)
                        Button("+") { zoom = min(8, zoom * 1.25) }
                            .disabled(zoom >= 8).accessibilityLabel("Zoom in ABBA result")
                    }
                    if mode == .overlay {
                        HStack {
                            Text("Atlas opacity").font(.caption)
                            Slider(value: $opacity, in: 0...1).frame(width: 170)
                                .accessibilityLabel("ABBA atlas opacity")
                            Text("\(Int((opacity * 100).rounded()))%").font(.caption.monospacedDigit())
                            Spacer()
                        }
                    }
                    GeometryReader { geometry in
                        if let slice, let histology = NSImage(contentsOfFile: slice.histologyPath),
                           let pixels = histology.brainBuilderPixelSize {
                            let fitted = AtlasImageGeometry.aspectFitRect(imageSize: pixels, containerSize: geometry.size)
                            ScrollView([.horizontal, .vertical]) {
                                ZStack {
                                    Color.white
                                    if mode == .histology || mode == .overlay {
                                        Image(nsImage: histology).resizable().interpolation(.high)
                                    }
                                    if mode == .atlas || mode == .overlay,
                                       let atlas = NSImage(contentsOfFile: slice.atlasPath) {
                                        Image(nsImage: atlas).resizable().interpolation(.high)
                                            .opacity(mode == .overlay ? opacity : 1)
                                    }
                                    if mode == .borders, let overlay = NSImage(contentsOfFile: slice.overlayPath) {
                                        Image(nsImage: overlay).resizable().interpolation(.high)
                                    }
                                }
                                .frame(width: fitted.width * zoom, height: fitted.height * zoom)
                                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                            }
                            .accessibilityLabel("Official ABBA result for \(slice.title)")
                        }
                    }
                    .background(Color.white)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.1)))
                }
            }
            Text(preview.messages.joined(separator: " "))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Read-only result. The current affine project, acceptance decisions, and 3D tracks are unchanged.")
                .font(.callout)
        }
        .padding(20)
        .frame(minWidth: 940, idealWidth: 1200, minHeight: 680, idealHeight: 800)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
        .onAppear { selectedID = preview.slices.first?.id }
        .onChange(of: selectedID) { _, _ in zoom = 1 }
    }
}
