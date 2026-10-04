import SwiftUI

struct Brain3DRetrospectiveOverlayToggleBar: View {
    @Binding var visibility: Brain3DRetrospectiveOverlayVisibility
    var snapshot: Brain3DRetrospectiveOverlaySnapshot

    var body: some View {
        HStack(spacing: 7) {
            layerToggle(
                "Planned",
                systemImage: "line.diagonal",
                color: .yellow,
                isOn: $visibility.showsPlannedShanks,
                isDisabled: snapshot.plannedShanks.isEmpty,
                help: "Show planned physical shanks as solid lines"
            )
            layerToggle(
                "Observed A/B",
                systemImage: "line.diagonal.arrow",
                color: Color(nsColor: .lightGray),
                isOn: $visibility.showsObservedEvidence,
                isDisabled: snapshot.observedTracks.isEmpty,
                help: "Show undirected finite observed evidence as neutral dashed lines with A/B endpoints"
            )
            layerToggle(
                "Allen ROI",
                systemImage: "square.stack.3d.up.fill",
                color: .teal,
                isOn: $visibility.showsAllenROIMask,
                isDisabled: snapshot.allenROIs.isEmpty,
                help: "Show the exact accepted-section Allen mask and installed Allen reference meshes in 3D"
            )
            layerToggle(
                "ASR boxes",
                systemImage: "cube.transparent",
                color: .orange,
                isOn: $visibility.showsASRBoxes,
                isDisabled: snapshot.asrBoxes.isEmpty,
                help: "Show locked half-open ASR box ROI outlines"
            )

            Text("Retrospective evidence · not for navigation")
                .font(.caption2)
                .foregroundStyle(BrainBuilderTheme.secondaryText)
                .lineLimit(1)
        }
        .controlSize(.small)
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(BrainBuilderTheme.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Post-lock retrospective layers")
    }

    private func layerToggle(
        _ title: String,
        systemImage: String,
        color: Color,
        isOn: Binding<Bool>,
        isDisabled: Bool,
        help: String
    ) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(isOn.wrappedValue ? color : BrainBuilderTheme.secondaryText)
        }
        .toggleStyle(.button)
        .disabled(isDisabled)
        .help(help)
    }
}

struct Brain3DRetrospectiveSliceOverlay: View {
    var snapshot: Brain3DRetrospectiveOverlaySnapshot
    var visibility: Brain3DRetrospectiveOverlayVisibility
    var placement: AtlasSlicePlacement
    var imagePixelSize: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            let fitted = AtlasImageGeometry.aspectFitRect(
                imageSize: imagePixelSize,
                containerSize: canvasSize
            )
            context.clip(to: Path(fitted))

            if visibility.showsASRBoxes {
                for box in snapshot.asrBoxes {
                    let polygon = Brain3DRetrospectiveOverlayGeometry.sliceBoxPolygon(
                        box,
                        placement: placement
                    )
                    guard polygon.count >= 3 else { continue }
                    var path = Path()
                    path.move(to: containerPoint(polygon[0], fitted: fitted))
                    for point in polygon.dropFirst() {
                        path.addLine(to: containerPoint(point, fitted: fitted))
                    }
                    path.closeSubpath()
                    context.fill(path, with: .color(.orange.opacity(0.08)))
                    context.stroke(
                        path,
                        with: .color(.orange.opacity(0.95)),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                }
            }

            if visibility.showsPlannedShanks {
                for segment in snapshot.plannedSegments {
                    draw(
                        segment,
                        in: context,
                        fitted: fitted,
                        color: .yellow,
                        strokeStyle: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                    )
                }
            }

            if visibility.showsObservedEvidence {
                for segment in snapshot.observedSegments {
                    draw(
                        segment,
                        in: context,
                        fitted: fitted,
                        color: Color(nsColor: .lightGray),
                        strokeStyle: StrokeStyle(
                            lineWidth: 2.2,
                            lineCap: .round,
                            dash: [7, 5]
                        )
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Post-lock retrospective overlay")
        .accessibilityValue(accessibilityValue)
    }

    private func draw(
        _ segment: Brain3DRetrospectiveSegment,
        in context: GraphicsContext,
        fitted: CGRect,
        color: Color,
        strokeStyle: StrokeStyle
    ) {
        guard let projected = Brain3DRetrospectiveOverlayGeometry.sliceSegment(
            segment,
            placement: placement
        ), projected.count == 2 else { return }
        let first = containerPoint(projected[0], fitted: fitted)
        let second = containerPoint(projected[1], fitted: fitted)
        let length = hypot(second.x - first.x, second.y - first.y)
        if length < 3 {
            context.fill(
                Path(ellipseIn: CGRect(x: first.x - 3, y: first.y - 3, width: 6, height: 6)),
                with: .color(color)
            )
            return
        }
        var path = Path()
        path.move(to: first)
        path.addLine(to: second)
        context.stroke(path, with: .color(color), style: strokeStyle)
    }

    private func containerPoint(_ point: CGPoint, fitted: CGRect) -> CGPoint {
        CGPoint(
            x: fitted.minX + point.x / imagePixelSize.width * fitted.width,
            y: fitted.minY + point.y / imagePixelSize.height * fitted.height
        )
    }

    private var accessibilityValue: String {
        var layers: [String] = []
        if visibility.showsPlannedShanks {
            layers.append("\(snapshot.plannedShanks.count) planned physical shanks, solid")
        }
        if visibility.showsObservedEvidence {
            layers.append("\(snapshot.observedTracks.count) observed finite A/B supports, dashed")
        }
        if visibility.showsAllenROIMask {
            layers.append("Allen ROI mask")
        }
        if visibility.showsASRBoxes {
            layers.append("\(snapshot.asrBoxes.count) ASR box outlines")
        }
        layers.append("retrospective only, not for navigation")
        return layers.joined(separator: ". ")
    }
}
