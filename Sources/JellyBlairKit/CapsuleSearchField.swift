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

/// A capsule icon button beside a CapsuleSearchField in a floating bar.
/// The capsule stretches to the bar's height, which the search field sets;
/// the bar's stack needs .fixedSize(horizontal: false, vertical: true) so
/// that height reaches the button. When on, the capsule fills with the
/// accent color.
public struct CapsuleIconButton: View {
    let iconName: String
    let iconWeight: Font.Weight
    let isOn: Bool
    let helpText: String
    let action: () -> Void

    @State private var isHovering = false

    public init(_ iconName: String, weight: Font.Weight = .regular, isOn: Bool = false, help: String, action: @escaping () -> Void) {
        self.iconName = iconName
        iconWeight = weight
        self.isOn = isOn
        helpText = help
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.callout.weight(iconWeight))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 8)
                .background(
                    Capsule()
                        .fill(isOn ? Color.accentColor : Color.primary.opacity(isHovering ? 0.12 : 0.06))
                        .animation(.easeOut(duration: 0.1), value: isHovering)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
    }
}
