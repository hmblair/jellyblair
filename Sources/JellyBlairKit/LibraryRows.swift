import SwiftUI

/// A sidebar or list row for one book, with level bars on the loaded one.
public struct BookRow: View {
    let book: Book
    let isLoaded: Bool

    @Environment(BookCatalog.self) private var catalog
    @Environment(PlayerController.self) private var player

    public init(book: Book, isLoaded: Bool) {
        self.book = book
        self.isLoaded = isLoaded
    }

    @State private var isHovering = false

    public var body: some View {
        HStack(spacing: 10) {
            BookCoverImage(bookID: book.id, url: catalog.coverURL(for: book), contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(book.name)
                    .font(.title3)
                    .lineLimit(1)
                Text(formatHoursMinutes(book.runTimeSeconds))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if catalog.model(for: book).downloadState == .downloaded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.green)
            }
            if isLoaded {
                AudioBarsView(meter: player.audioMeter, isPlaying: player.isPlaying)
            }
        }
        .padding(.vertical, 2)
        // The row stretches to the full cell width, so hover responds
        // anywhere the click does.
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // The hover pill mimics the system selection pill. Its geometry is
        // not exposed by SwiftUI, so these insets mirror it by observation
        // and may need retuning after a macOS update.
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
                .opacity(isHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.1), value: isHovering)
                .padding(.horizontal, 10)
        )
        .onHover { isHovering = $0 }
    }
}

/// A group section heading: plain text in the platform's header style,
/// clickable across its full width when it has an action. A scoped list's
/// heading carries the role icon, and on the Mac a back chevron.
public struct GroupHeading: View {
    let name: String
    let iconName: String?
    let showsBackChevron: Bool
    let action: (() -> Void)?

    public init(name: String, iconName: String? = nil, showsBackChevron: Bool = false, action: (() -> Void)? = nil) {
        self.name = name
        self.iconName = iconName
        self.showsBackChevron = showsBackChevron
        self.action = action
    }

    public var body: some View {
        if let action {
            Button(action: action) {
                label
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            if showsBackChevron {
                Image(systemName: "chevron.left")
                    .font(.caption)
            }
            if let iconName {
                Image(systemName: iconName)
                    .imageScale(.small)
            }
            Text(name)
                .font(.callout)
            Spacer()
        }
    }
}
