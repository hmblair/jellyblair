import SwiftUI

/// The signed-in app: the library beside the book screen when the layout is
/// regular, or one screen at a time when it is compact, with the playback bar
/// under both. It owns the selection and the navigation, so each shell keeps
/// only what belongs to its own platform.
public struct MainView: View {
    let scope: SessionScope

    @Environment(\.layoutDensity) private var density

    /// Selection is tracked by ID, so it survives library refreshes that
    /// replace the Book values.
    @State private var selectedBookID: String?

    /// The list's group scope, owned here so the book screen can set it.
    @State private var listScope: BookGroup?

    /// Which columns the split view shows, read so the library's toolbar
    /// buttons can leave with the sidebar.
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    /// The compact layout's stack of pushed screens.
    @State private var path: [LibraryRoute] = []

    public init(scope: SessionScope) {
        self.scope = scope
    }

    private static let sidebarMinWidth: CGFloat = 220
    private static let sidebarIdealWidth: CGFloat = 260

    public var body: some View {
        layout
            .task {
                scope.connection.start()
                await scope.library.load()
            }
            .onChange(of: scope.connection.isServerReachable) { _, reachable in
                guard reachable, scope.library.errorMessage != nil else { return }
                Task { await scope.library.load() }
            }
            .environment(\.openAuthor, OpenBookGroupAction { openGroup(ofKind: .author, named: $0) })
            .environment(\.openNarrator, OpenBookGroupAction { openGroup(ofKind: .narrator, named: $0) })
            .environment(\.openGenre, OpenBookGroupAction { openGroup(ofKind: .genre, named: $0) })
            .environment(scope.library)
            .environment(scope.player)
            .environment(scope.connection)
            .environment(scope.catalog)
    }

    @ViewBuilder
    private var layout: some View {
        switch density {
        case .regular:
            regularLayout
        case .compact:
            compactLayout
        }
    }

    // MARK: - Regular

    /// The library in a sidebar beside the selected book's screen. The
    /// offline indicator sits under the sidebar, where it does not crowd
    /// the book screen.
    private var regularLayout: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarList
                    .navigationSplitViewColumnWidth(min: Self.sidebarMinWidth, ideal: Self.sidebarIdealWidth)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        OfflineIndicator()
                    }
            } detail: {
                detail
            }
            // The sidebar shares the width rather than overlaying the book
            // screen, which is what a two-column layout is for.
            .navigationSplitViewStyle(.balanced)

            playbackBar
        }
    }

    private var sidebarList: some View {
        LibraryList(selection: $selectedBookID, scope: $listScope, isShowing: isSidebarShowing)
    }

    /// True while the split view shows its sidebar.
    private var isSidebarShowing: Bool {
        columnVisibility != .detailOnly
    }

    private var selectedBook: Book? {
        scope.library.book(withID: selectedBookID)
    }

    /// The book screen for the selected book, or a placeholder. The book
    /// screen carries its own settings button. The placeholder declares one,
    /// so the title bar keeps the button with no selection.
    private var detail: some View {
        Group {
            if let selectedBook {
                BookView(book: selectedBook)
                    .id(selectedBook.id)
            } else {
                ContentUnavailableView("Select an audiobook", systemImage: "headphones")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            SettingsToolbarButton()
                        }
                    }
            }
        }
        .detailWidthFloor()
    }

    // MARK: - Compact

    /// One screen at a time. The offline indicator sits below the playback
    /// bar, since there is no second column to put it under.
    private var compactLayout: some View {
        VStack(spacing: 0) {
            NavigationStack(path: $path) {
                rootList
                    .navigationDestination(for: LibraryRoute.self) { route in
                        destination(for: route)
                    }
            }
            playbackBar
            OfflineIndicator()
                .background(.bar)
        }
    }

    private var rootList: some View {
        LibraryList(selection: pushingSelection, scope: .constant(nil))
    }

    /// A compact layout has no detail pane to fill, so a chosen book is
    /// pushed and no selection is left behind. Choosing the same book again
    /// pushes it again.
    private var pushingSelection: Binding<String?> {
        Binding(
            get: { nil },
            set: { [library = scope.library] id in
                guard let book = library.book(withID: id) else { return }
                path.append(.book(book))
            }
        )
    }

    @ViewBuilder
    private func destination(for route: LibraryRoute) -> some View {
        switch route {
        case .book(let book):
            // Identity per book: the playback bar replaces the route in
            // place, and without this the screen keeps the previous book's
            // list state.
            BookView(book: book)
                .id(book.id)
                .inlineNavigationTitle()
        case .group(let group):
            LibraryList(selection: pushingSelection, scope: .constant(group))
        }
    }

    // MARK: - Shared

    /// The bar is a stack sibling, not a safe-area inset: an inset lets
    /// scrollable screens extend their frames beneath it, which would put
    /// the panes' fades and centering at the screen bottom instead of the bar.
    private var playbackBar: some View {
        PlaybackBar { book in
            openBook(book)
        }
    }

    /// Shows the loaded book's screen when the playback bar is tapped.
    private func openBook(_ book: Book) {
        switch density {
        case .regular:
            selectedBookID = book.id
        case .compact:
            path = [.book(book)]
        }
    }

    /// Opens a named group of books. A regular layout swaps its list's scope
    /// in place, and a compact layout pushes the group onto its stack.
    private func openGroup(ofKind kind: BookGroup.Kind, named name: String) {
        guard let group = scope.library.group(ofKind: kind, named: name) else { return }
        switch density {
        case .regular:
            listScope = group
        case .compact:
            path.append(.group(group))
        }
    }
}

/// A screen the library can navigate to when it cannot show one beside itself.
enum LibraryRoute: Hashable {
    case book(Book)
    case group(BookGroup)
}

extension View {
    /// An inline title bar, which iOS alone has.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        return navigationBarTitleDisplayMode(.inline)
        #else
        return self
        #endif
    }

    /// The Mac window's minimum width comes from its content: this floor and
    /// the sidebar's minimum column width together. No other platform sizes a
    /// window, so none sets a floor.
    fileprivate func detailWidthFloor() -> some View {
        #if os(macOS)
        return frame(minWidth: 440)
        #else
        return self
        #endif
    }
}
