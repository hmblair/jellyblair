import Foundation

/// The comparison options a search uses: exact, or case-insensitive by
/// default. Every search in the app derives its options here, so the two
/// panes and the row highlighting cannot disagree on what matches.
func searchCompareOptions(caseSensitive: Bool) -> NSString.CompareOptions {
    caseSensitive ? [] : [.caseInsensitive]
}

/// Every occurrence of the query in the text, in order, up to the limit.
/// Checks for cancellation periodically and returns what it has.
func findOccurrences(
    of query: String,
    in text: NSString,
    caseSensitive: Bool,
    limit: Int = .max,
    isCancelled: () -> Bool = { false }
) -> [NSRange] {
    guard !query.isEmpty else { return [] }
    let options = searchCompareOptions(caseSensitive: caseSensitive)
    var ranges: [NSRange] = []
    var start = 0
    var steps = 0
    while start < text.length {
        let range = text.range(of: query, options: options, range: NSRange(location: start, length: text.length - start))
        guard range.location != NSNotFound else { break }
        ranges.append(range)
        if ranges.count >= limit { break }
        start = range.location + max(range.length, 1)
        steps += 1
        if steps % 512 == 0, isCancelled() { break }
    }
    return ranges
}
