import SwiftUI

/// Height of the zone a floating bar occupies over a list.
public let floatingBarZoneHeight: CGFloat = 34

/// Fades a list's rows to nothing under the floating bar's zone, and
/// optionally into the bottom edge.
private struct FloatingBarFade: ViewModifier {
    let fadesBottom: Bool

    func body(content: Content) -> some View {
        content.mask(
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: floatingBarZoneHeight)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 22)
                Rectangle()
                if fadesBottom {
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 22)
                }
            }
        )
    }
}

public extension View {
    /// Fades the view's top under a floating bar, and optionally its bottom
    /// into the screen edge.
    func fadedUnderFloatingBar(fadesBottom: Bool = false) -> some View {
        modifier(FloatingBarFade(fadesBottom: fadesBottom))
    }
}

/// The floating bar over a library list: the search field, the grouping
/// toggle when the list is unscoped, and the downloaded-only filter.
public struct LibraryFilterBar: View {
    @Binding var searchQuery: String
    @Binding var showDownloadedOnly: Bool
    let showsGroupToggle: Bool

    @Environment(LibraryViewModel.self) private var library

    @State private var isHoveringGroupToggle = false
    @State private var isHoveringFilter = false

    #if os(macOS)
    private static let filterIconSize: CGFloat = 24
    #else
    private static let filterIconSize: CGFloat = 27
    #endif

    public init(searchQuery: Binding<String>, showDownloadedOnly: Binding<Bool>, showsGroupToggle: Bool) {
        _searchQuery = searchQuery
        _showDownloadedOnly = showDownloadedOnly
        self.showsGroupToggle = showsGroupToggle
    }

    public var body: some View {
        HStack(spacing: 8) {
            CapsuleSearchField("Search", text: $searchQuery)
            if showsGroupToggle {
                groupToggle
            }
            filterToggle
        }
    }

    /// Cycles the library grouping through author, narrator, and genre.
    private var groupToggle: some View {
        Button {
            library.groupKind = library.groupKind.next
        } label: {
            Image(systemName: library.groupKind.iconName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(isHoveringGroupToggle ? 0.12 : 0.06))
                        .animation(.easeOut(duration: 0.1), value: isHoveringGroupToggle)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHoveringGroupToggle = $0 }
        .help("Change the grouping")
    }

    private var filterToggle: some View {
        Button {
            showDownloadedOnly.toggle()
        } label: {
            // Unselected, the icon wears the search capsule's own tone,
            // with the arrow in the capsule's placeholder gray.
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: Self.filterIconSize))
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    showDownloadedOnly ? Color.white : Color.secondary,
                    showDownloadedOnly ? Color.green : Color.primary.opacity(isHoveringFilter ? 0.12 : 0.06)
                )
                .animation(.easeOut(duration: 0.1), value: isHoveringFilter)
        }
        .buttonStyle(.plain)
        .onHover { isHoveringFilter = $0 }
        .help(showDownloadedOnly ? "Show all books" : "Show only downloaded books")
    }
}

/// The library list's empty states: loading, a failed first load, or no
/// search matches. A refresh failure keeps the current list; these only
/// cover an empty one.
public struct LibraryEmptyOverlay: View {
    let hasVisibleContent: Bool
    let searchQuery: String

    @Environment(LibraryViewModel.self) private var library

    public init(hasVisibleContent: Bool, searchQuery: String) {
        self.hasVisibleContent = hasVisibleContent
        self.searchQuery = searchQuery
    }

    public var body: some View {
        if library.books.isEmpty {
            if library.isLoading {
                ProgressView()
            } else if let message = library.errorMessage {
                ContentUnavailableView("Cannot load the library", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        } else if !hasVisibleContent {
            ContentUnavailableView.search(text: searchQuery)
        }
    }
}
