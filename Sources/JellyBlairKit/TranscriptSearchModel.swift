import Foundation

/// The result of a settled search, for the owner to install.
struct TranscriptSearchOutcome {
    /// True when the match ranges changed, so the document's colors need a
    /// repaint.
    let needsRepaint: Bool
    /// The match a fresh query lands on, for the owner to center.
    let landingMatch: NSRange?
}

/// Owns the transcript's search: the query lifecycle, the background
/// match-finding task, and the match list with its selected position. The
/// owner reads the matches and reacts to settled searches through the
/// callbacks; painting and scrolling stay outside.
@MainActor
final class TranscriptSearchModel {
    /// UTF-16 ranges of the search matches inside the storage, in order.
    private(set) var matches: [NSRange] = []
    /// The position of the selected match.
    private(set) var matchIndex = 0
    /// The query whose search last started, and its case sensitivity.
    private(set) var appliedQuery = ""
    private(set) var appliedCaseSensitive = false

    /// The query whose matches finished, and its case sensitivity.
    private var completedQuery = ""
    private var completedCaseSensitive = false
    private var searchTask: Task<Void, Never>?

    /// The storage offset of the current line's start, read when a fresh
    /// query picks its landing match.
    var readStart: () -> Int = { 0 }
    /// Called when a search starts or settles.
    var onSearchingChanged: ((Bool) -> Void)?
    /// Called when a search settles, with what the owner must install.
    var onFinish: ((TranscriptSearchOutcome) -> Void)?

    /// Starts a background search for the query, restarting any search
    /// underway. A blank query clears the matches directly.
    func apply(query: String, caseSensitive: Bool, text: String) {
        appliedQuery = query
        appliedCaseSensitive = caseSensitive
        searchTask?.cancel()
        searchTask = nil
        guard !query.isEmpty else {
            let needsRepaint = !matches.isEmpty
            matches = []
            matchIndex = 0
            completedQuery = ""
            onSearchingChanged?(false)
            onFinish?(TranscriptSearchOutcome(needsRepaint: needsRepaint, landingMatch: nil))
            return
        }
        onSearchingChanged?(true)
        // A result that hit the match limit covers only the document's start,
        // so narrowing from it would lose every match past the cutoff. A
        // result of a different sensitivity does not contain this search's
        // match starts at all.
        let narrowing = matches.isEmpty || matches.count >= Self.matchLimit || completedCaseSensitive != caseSensitive
            ? nil
            : (query: completedQuery, ranges: matches)
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            let ranges = Self.findMatches(of: query, in: text, caseSensitive: caseSensitive, narrowingFrom: narrowing)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.finish(query: query, caseSensitive: caseSensitive, ranges: ranges)
            }
        }
    }

    /// Installs a finished search: a fresh query lands on the first match
    /// at or past the current line, and a narrowed one keeps its position.
    private func finish(query: String, caseSensitive: Bool, ranges: [NSRange]) {
        guard query == appliedQuery, caseSensitive == appliedCaseSensitive else { return }
        let isFreshQuery = query != completedQuery || caseSensitive != completedCaseSensitive
        // With no matches before or after there is nothing to repaint.
        let needsRepaint = !matches.isEmpty || !ranges.isEmpty
        matches = ranges
        completedQuery = query
        completedCaseSensitive = caseSensitive
        var landing: NSRange?
        if isFreshQuery {
            matchIndex = nearestForwardMatch()
            landing = matches.isEmpty ? nil : matches[matchIndex]
        } else {
            matchIndex = min(matchIndex, max(0, ranges.count - 1))
        }
        onSearchingChanged?(false)
        onFinish?(TranscriptSearchOutcome(needsRepaint: needsRepaint, landingMatch: landing))
    }

    /// Steps to the next or previous match, wrapping, and returns it for
    /// the owner to center.
    func stepMatch(by delta: Int) -> NSRange? {
        let count = matches.count
        guard count > 0 else { return nil }
        matchIndex = ((matchIndex + delta) % count + count) % count
        return matches[matchIndex]
    }

    /// Drops the matches when the content is replaced: the old ranges
    /// refer to the old text.
    func reset() {
        matches = []
        matchIndex = 0
        completedQuery = ""
        completedCaseSensitive = false
    }

    /// Stops any background search.
    func cancel() {
        searchTask?.cancel()
        searchTask = nil
    }

    /// The position of the first match at or after the current line,
    /// wrapping to the first match overall.
    private func nearestForwardMatch() -> Int {
        guard !matches.isEmpty else { return 0 }
        let location = readStart()
        let position = matches.partitioningIndex { $0.location >= location }
        return position < matches.count ? position : 0
    }

    /// Upper bound on collected matches, so a one-letter query stays fast.
    nonisolated private static let matchLimit = 10_000

    /// Every occurrence of the query in the text, in order, up to the match
    /// limit. When the finished previous query is a prefix of this one, only
    /// the previous match starts are tested.
    nonisolated private static func findMatches(of query: String, in text: String, caseSensitive: Bool, narrowingFrom previous: (query: String, ranges: [NSRange])?) -> [NSRange] {
        let full = text as NSString
        guard let previous, !previous.query.isEmpty,
              extends(previous.query, to: query, caseSensitive: caseSensitive)
        else {
            return findOccurrences(of: query, in: full, caseSensitive: caseSensitive, limit: matchLimit) { Task.isCancelled }
        }
        let options = searchCompareOptions(caseSensitive: caseSensitive).union(.anchored)
        var ranges: [NSRange] = []
        for candidate in previous.ranges {
            let remaining = NSRange(location: candidate.location, length: full.length - candidate.location)
            let match = full.range(of: query, options: options, range: remaining, locale: searchLocale)
            if match.location != NSNotFound {
                ranges.append(match)
                if ranges.count >= matchLimit { break }
            }
        }
        return ranges
    }

    /// True when the new query extends the old, so every new match starts at
    /// an old match's start.
    nonisolated private static func extends(_ old: String, to new: String, caseSensitive: Bool) -> Bool {
        caseSensitive ? new.hasPrefix(old) : new.lowercased().hasPrefix(old.lowercased())
    }
}
