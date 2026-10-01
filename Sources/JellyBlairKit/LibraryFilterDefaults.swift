import SwiftUI

/// The filters a library list starts with, stored app-wide so the settings
/// screens can change them outside the list's scope. The search query is
/// left out, since a list always opens with an empty one.
public enum DefaultLibraryFilters {
    public static let key = "defaultLibraryFilters"

    /// The stored filters, which the library list opens with.
    public static var stored: LibraryFilters {
        decode(UserDefaults.standard.data(forKey: key) ?? Data())
    }

    /// The filters the list of a group of the kind opens with. No filter
    /// toggle is on, so the defaults hide none of the books of a person, a
    /// series, a publisher, or a genre. The sort order is the one that
    /// suits the kind, or the stored one when the kind has none.
    public static func storedForGroup(ofKind kind: BookGroup.Kind?) -> LibraryFilters {
        var filters = stored.clearingFilters()
        filters.setSortOrder(suiting: kind)
        return filters
    }

    /// The filters the data holds, or a plain set when it holds none.
    static func decode(_ data: Data) -> LibraryFilters {
        (try? JSONDecoder().decode(LibraryFilters.self, from: data)) ?? LibraryFilters()
    }

    static func encode(_ filters: LibraryFilters) -> Data {
        (try? JSONEncoder().encode(filters)) ?? Data()
    }
}

/// The default sort order and filters as two rows, one for each of the
/// library's menus, for both platforms' settings screens. A sort chosen
/// here shows in every list opened afterwards, except the list of a
/// series, which opens in its own order. A filter chosen here shows in
/// the library list only; a group's list opens unfiltered.
public struct DefaultLibraryFilterSettings: View {
    @AppStorage(DefaultLibraryFilters.key) private var storedFilters = Data()

    public init() {}

    public var body: some View {
        menuRow(icon: sortMenuIcon, title: Text("Default Sort"), value: sortSummary) {
            LibrarySortMenuChoices(filters: filters)
        }
        menuRow(icon: filterMenuIcon, title: Text("Default Filters"), value: filterSummary) {
            LibraryFilterMenuChoices(filters: filters)
        }
    }

    /// One row that opens a menu: the row's name behind its icon, with the
    /// current choice on the trailing side, like the book details rows.
    private func menuRow(icon: Icon, title: Text, value: Text, @ViewBuilder choices: () -> some View) -> some View {
        Menu {
            choices()
        } label: {
            LabeledContent {
                value
                    .foregroundStyle(.secondary)
            } label: {
                Label {
                    title
                } icon: {
                    // The explicit style overrides the phone form's own
                    // accent tint on label icons.
                    icon.plain
                        .foregroundStyle(.primary)
                }
                .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    /// The order's name.
    private var sortSummary: Text {
        Text(filters.wrappedValue.sortOrder.label)
    }

    /// The filters that are on, in menu order, or "None" when the list
    /// opens unfiltered.
    private var filterSummary: Text {
        let active = filters.wrappedValue.activeFilters
        guard !active.isEmpty else { return Text("None") }
        return Text(active.map(\.adjective).joined(separator: ", "))
    }

    /// The stored filters as the menus read and write them.
    private var filters: Binding<LibraryFilters> {
        Binding {
            DefaultLibraryFilters.decode(storedFilters)
        } set: {
            storedFilters = DefaultLibraryFilters.encode($0)
        }
    }
}
