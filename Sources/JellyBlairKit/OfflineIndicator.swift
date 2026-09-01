import SwiftUI

/// A quiet caption shown while the server is unreachable.
/// The connection monitor is the one source of that knowledge.
public struct OfflineIndicator: View {
    @Environment(ConnectionMonitor.self) private var connection

    public init() {}

    public var body: some View {
        if !connection.isServerReachable {
            Label("Offline", systemImage: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
        }
    }
}
