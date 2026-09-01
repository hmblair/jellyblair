import SwiftUI

/// The app's search field: a slim capsule with a magnifier and a clear
/// button, used by the library and chapter lists.
public struct CapsuleSearchField: View {
    let prompt: String
    @Binding var text: String

    public init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        _text = text
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.06))
        )
    }
}
