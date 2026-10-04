import AppKit
import SwiftUI

struct RegistrationCorrectionSheet: View {
    @ObservedObject var store: BrainProjectStore
    @Environment(\.dismiss) private var dismiss
    @State private var correction: RegistrationCorrection
    @State private var apText: String
    @State private var pitchText: String
    @State private var yawText: String
    @State private var pendingAtlasPoint: RegistrationPoint?
    @State private var atlasZoom = 1.0
    @State private var sliceZoom = 1.0
    @State private var message = "Choose the same anatomical feature in Atlas, then Histology."

    init(store: BrainProjectStore) {
        self.store = store
        let initialCorrection = RegistrationCorrection(
            pose: store.selectedRegistrationSlice?.pose
                ?? .estimated(apMicrons: 0, confidence: 0, provenance: "")
        )
        _correction = State(initialValue: initialCorrection)
        _apText = State(initialValue: String(initialCorrection.atlasAPMicrons))
        _pitchText = State(initialValue: String(initialCorrection.pitchDegrees))
        _yawText = State(initialValue: String(initialCorrection.yawDegrees))
    }

    private var enteredCorrection: RegistrationCorrection? {
        guard let ap = Double(apText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let pitch = Double(pitchText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let yaw = Double(yawText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        var result = correction
        result.atlasAPMicrons = ap
        result.pitchDegrees = pitch
        result.yawDegrees = yaw
        return result.hasValidPlane ? result : nil
    }

    private var planeChanged: Bool {
        guard let pose = store.selectedRegistrationSlice?.pose,
              let enteredCorrection else { return true }
        return !enteredCorrection.matchesPlane(pose)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Correct \(store.selectedRegistrationSlice?.title ?? "section")")
                        .font(.title2.weight(.semibold))
                    Text("Adjust the atlas plane first, then match landmarks across both images.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.isBusy)
            }

            HStack(alignment: .bottom, spacing: 18) {
                planeField("AP · µm from atlas origin", text: $apText)
                planeField("Tilt top/bottom · degrees", text: $pitchText)
                planeField("Tilt left/right · degrees", text: $yawText)
                Button("Apply plane") { apply(landmarks: false) }
                    .disabled(!planeChanged || enteredCorrection == nil || store.isBusy)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))

            if enteredCorrection == nil {
                Label("Enter valid AP and tilt values to continue.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if planeChanged {
                Label("Apply the plane before adding landmarks. Existing pairs will be cleared.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 16) {
                LandmarkImagePane(
                    title: "1 · Atlas", path: store.selectedRegistrationSlice?.artifacts?.atlasReferencePath,
                    points: correction.landmarks.map(\.atlasPoint), pending: pendingAtlasPoint,
                    zoom: $atlasZoom, isEnabled: !planeChanged && !store.isBusy
                ) { point in
                    pendingAtlasPoint = point
                    message = "Now click the matching feature in Histology."
                }
                LandmarkImagePane(
                    title: "2 · Histology", path: store.selectedRegistrationSlice?.artifacts?.structuralImagePath,
                    points: correction.landmarks.map(\.slicePoint), pending: nil,
                    zoom: $sliceZoom, isEnabled: !planeChanged && !store.isBusy && pendingAtlasPoint != nil
                ) { point in
                    guard let atlasPoint = pendingAtlasPoint else { return }
                    correction.landmarks.append(ManualLandmarkPair(
                        id: UUID().uuidString, atlasPoint: atlasPoint, slicePoint: point,
                        label: "Landmark \(correction.landmarks.count + 1)"
                    ))
                    pendingAtlasPoint = nil
                    message = "Pair \(correction.landmarks.count) added. Choose another feature in Atlas."
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Text("\(correction.landmarks.count) landmark pairs")
                    .font(.headline.monospacedDigit())
                Button("Undo point") {
                    if pendingAtlasPoint != nil { pendingAtlasPoint = nil }
                    else if !correction.landmarks.isEmpty { correction.landmarks.removeLast() }
                }
                .disabled(store.isBusy || (pendingAtlasPoint == nil && correction.landmarks.isEmpty))
                Button("Clear") {
                    correction.landmarks = []
                    pendingAtlasPoint = nil
                }
                .disabled(store.isBusy || (pendingAtlasPoint == nil && correction.landmarks.isEmpty))
                Spacer()
                Button("Apply landmark correction") { apply(landmarks: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isBusy || planeChanged || !correction.hasUsableLandmarks || pendingAtlasPoint != nil)
            }

            Text("Use at least 3 non-collinear pairs; 4 or more spread across the section help reveal disagreement. Fit residual is measured on these same points, not independent accuracy.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                if store.isRunningRegistrationWorker {
                    ProgressView().controlSize(.small)
                    Text(store.status).lineLimit(2)
                    Spacer()
                    Button("Cancel") { store.cancelRegistrationWorker() }
                        .disabled(store.isCancelingRegistrationWorker)
                } else {
                    Text(message).lineLimit(2)
                    Spacer()
                    if let rms = store.selectedRegistrationSlice?.qc.landmarkRMSErrorMicrons {
                        Text(String(format: "Fit residual %.1f µm", rms)).monospacedDigit()
                    }
                }
            }
            .font(.callout)
        }
        .padding(20)
        .frame(minWidth: 900, idealWidth: 1160, minHeight: 650, idealHeight: 780)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .interactiveDismissDisabled(store.isBusy)
        .onChange(of: store.isRunningRegistrationWorker) { _, running in
            if !running { message = store.status }
        }
    }

    private func planeField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            // Text editing must not round the saved plane when a field receives focus.
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 165)
                .disabled(store.isBusy)
        }
    }

    private func apply(landmarks: Bool) {
        guard var request = enteredCorrection else { return }
        if !landmarks { request.landmarks = [] }
        store.correctSelectedRegistrationSlice(request) { slice in
            if let pose = slice.pose {
                correction = RegistrationCorrection(pose: pose)
                apText = String(correction.atlasAPMicrons)
                pitchText = String(correction.pitchDegrees)
                yawText = String(correction.yawDegrees)
            }
            pendingAtlasPoint = nil
            message = landmarks
                ? "Correction saved for review. Inspect the overlay before accepting the section."
                : "Atlas plane updated. Add landmarks on this reference plane."
        }
    }
}

private struct LandmarkImagePane: View {
    var title: String
    var path: String?
    var points: [RegistrationPoint]
    var pending: RegistrationPoint?
    @Binding var zoom: Double
    var isEnabled: Bool
    var onPoint: (RegistrationPoint) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("−") { zoom = max(1, zoom / 1.4) }.accessibilityLabel("Zoom out \(title)")
                Text("\(Int(zoom * 100))%")
                    .font(.caption.monospacedDigit()).frame(width: 40)
                Button("+") { zoom = min(8, zoom * 1.4) }.accessibilityLabel("Zoom in \(title)")
                Button("Fit") { zoom = 1 }
            }
            GeometryReader { geometry in
                if let path, let image = NSImage(contentsOfFile: path), let pixels = image.brainBuilderPixelSize {
                    let fitted = AtlasImageGeometry.aspectFitRect(imageSize: pixels, containerSize: geometry.size)
                    let size = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: size.width, height: size.height)
                            .overlay(alignment: .topLeading) {
                                ZStack(alignment: .topLeading) {
                                    ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                                        marker("\(index + 1)", point: point, size: size, pixels: pixels, color: .yellow)
                                    }
                                    if let pending {
                                        marker("+", point: pending, size: size, pixels: pixels, color: .cyan)
                                    }
                                }
                                .allowsHitTesting(false)
                            }
                            .contentShape(Rectangle())
                            .gesture(SpatialTapGesture().onEnded { event in
                                guard isEnabled, size.width > 0, size.height > 0 else { return }
                                guard event.location.x >= 0, event.location.y >= 0,
                                      event.location.x < size.width, event.location.y < size.height else { return }
                                let x = min(pixels.width - 1, max(0, event.location.x * pixels.width / size.width - 0.5))
                                let y = min(pixels.height - 1, max(0, event.location.y * pixels.height / size.height - 0.5))
                                onPoint(RegistrationPoint(x: x, y: y))
                            })
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                    .accessibilityLabel("\(title) landmark image")
                    .accessibilityHint("Click an anatomical feature; scroll to pan after zooming.")
                } else {
                    ContentUnavailableView("Image unavailable", systemImage: "photo")
                }
            }
            .background(Color.white)
            .overlay { Rectangle().stroke(Color.black.opacity(0.15)) }
        }
    }

    private func marker(_ label: String, point: RegistrationPoint, size: CGSize, pixels: CGSize, color: Color) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .bold).monospacedDigit())
            .foregroundStyle(.black)
            .frame(width: 22, height: 22)
            .background(color, in: Circle())
            .overlay { Circle().stroke(.black, lineWidth: 1) }
            .position(x: (point.x + 0.5) / pixels.width * size.width, y: (point.y + 0.5) / pixels.height * size.height)
    }
}
