import SwiftUI

/// The app's search field: a slim capsule with a magnifier, a clear button,
/// and room for a trailing accessory, used by the library and chapter lists.
public struct CapsuleSearchField<Accessory: View>: View {
    let prompt: String
    @Binding var text: String
    let accessory: Accessory

    public init(_ prompt: String, text: Binding<String>, @ViewBuilder accessory: () -> Accessory) {
        self.prompt = prompt
        _text = text
        self.accessory = accessory()
    }

    public var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            accessory
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

public extension CapsuleSearchField where Accessory == EmptyView {
    init(_ prompt: String, text: Binding<String>) {
        self.init(prompt, text: text) { EmptyView() }
    }
}
