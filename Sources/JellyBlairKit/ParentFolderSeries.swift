import Foundation

extension BookItem {
    /// The folder that holds the book, among the given folders keyed by
    /// identifier.
    func parentFolder(in folders: [String: FolderRecord]) -> FolderRecord? {
        parentID.flatMap { folders[$0] }
    }

    /// The book's record, in the series its parent folder names when the
    /// record has no series of its own.
    func recordWithSeries(fromParentFolder folder: FolderRecord?) -> BookRecord {
        guard record.series == nil, let series = folder.flatMap(seriesName(from:)) else { return record }
        return record.withSeries(series)
    }

    /// The series the folder names for the book. A folder names a series
    /// when it is a plain folder inside a library and no person on the
    /// book carries its name.
    private func seriesName(from folder: FolderRecord) -> String? {
        guard folder.isPlainFolder, !isNameOfPerson(folder.name) else { return nil }
        return folder.name
    }

    /// True when a person in any role on the book carries the name.
    private func isNameOfPerson(_ name: String) -> Bool {
        PersonRole.allCases.contains { record.names(for: $0).contains(name) }
    }
}
