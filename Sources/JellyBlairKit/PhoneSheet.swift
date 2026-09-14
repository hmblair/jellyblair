import SwiftUI

/// The phone's sheet chrome, shared by the settings, file information,
/// chapter, and transcript sheets so all present identically: a navigation
/// bar with the title over the content, opening at the medium detent and
/// expanding to full height. Swiping down closes the sheet.
public struct PhoneSheet<Content: View>: View {
    private let title: Text
    private let content: Content

    public init(title: Text, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
        }
        .presentationDetents([.medium, .large])
    }
}
