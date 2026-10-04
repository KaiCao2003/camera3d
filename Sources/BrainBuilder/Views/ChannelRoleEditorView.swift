import SwiftUI

struct ChannelRoleEditorView: View {
    @ObservedObject var store: BrainProjectStore

    var body: some View {
        if let project = store.registrationProject {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(project.channelMappings) { channel in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(for: channel.pseudoColor))
                            .frame(width: 8, height: 8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.name)
                                .lineLimit(1)
                            Text("Channel \(channel.channelIndex)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Picker(
                            channel.name,
                            selection: Binding(
                                get: { channel.role },
                                set: { store.updateChannelRole(channelIndex: channel.channelIndex, role: $0) }
                            )
                        ) {
                            ForEach(RegistrationChannelRole.allCases) { role in
                                Text(role.title).tag(role)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 118)
                        .disabled(store.isBusy)
                    }
                }
            }
        }
    }

    private func color(for pseudoColor: String?) -> Color {
        switch pseudoColor?.lowercased() {
        case "green":
            .green
        case "red":
            .red
        case "blue":
            .blue
        default:
            .secondary
        }
    }
}
