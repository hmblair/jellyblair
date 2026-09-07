import SwiftUI

/// Opens the app's settings; injected per shell, since the Mac opens a
/// window and the phone presents a sheet.
public struct OpenSettingsAction {
    private let handler: () -> Void

    public init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    public func callAsFunction() {
        handler()
    }
}

public extension EnvironmentValues {
    @Entry var openSettings: OpenSettingsAction?
}

/// Title bar button that opens the settings.
public struct SettingsToolbarButton: View {
    @Environment(\.openSettings) private var openSettings

    public init() {}

    public var body: some View {
        Button {
            openSettings?()
        } label: {
            Image(systemName: "gearshape")
        }
        .help("Show the settings")
    }
}
