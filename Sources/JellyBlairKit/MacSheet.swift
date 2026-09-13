import SwiftUI

/// Padding between a sheet's content and its edges, shared by the sheet
/// layouts on both platforms.
public let sheetEdgePadding: CGFloat = 20

#if os(macOS)
/// The Mac's sheet layout, shared by the settings and file information
/// sheets: a centered headline title over the content, with a Done button
/// at the bottom trailing edge.
public struct MacSheet<Content: View>: View {
    private let title: Text
    private let content: Content

    @Environment(\.dismiss) private var dismiss

    private static var width: CGFloat { 380 }

    public init(title: Text, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            title
                .font(.headline)
                .padding(.top, sheetEdgePadding)
            content
            HStack {
                Spacer()
                doneButton
            }
            .padding([.horizontal, .bottom], sheetEdgePadding)
            .padding(.top, 16)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Closes the sheet, which the Mac cannot swipe away.
    private var doneButton: some View {
        Button("Done") {
            dismiss()
        }
        .keyboardShortcut(.cancelAction)
    }
}
#endif
