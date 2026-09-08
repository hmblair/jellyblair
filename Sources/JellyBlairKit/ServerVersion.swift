import Foundation

/// A Jellyfin version, held as its numbers so that 12.0 ranks above 10.9.
/// Jellyfin dropped the leading 10 after 10.11, so the numbers must not be
/// compared as text.
public struct ServerVersion: Comparable, CustomStringConvertible {
    /// The oldest server the app works with. Jellyfin 10.9 is the first
    /// release that carries the single-item route, the played-item route,
    /// and the lyrics route the client calls.
    public static let minimumSupported = ServerVersion(numbers: [10, 9])

    private let numbers: [Int]

    private init(numbers: [Int]) {
        self.numbers = numbers
    }

    /// Reads a dotted version such as "10.10.7" or "12.0.0". Stops at the
    /// first part that does not start with a digit, so a build suffix does
    /// not defeat the parse. Returns nil for text that holds no number.
    public init?(_ text: String) {
        let leadingDigits = text.split(separator: ".").map { $0.prefix(while: \.isNumber) }
        let numbers = leadingDigits.prefix(while: { !$0.isEmpty }).compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        self.numbers = numbers
    }

    public var description: String {
        numbers.map(String.init).joined(separator: ".")
    }

    /// The number in one position, where a version that stops short of the
    /// position reads as zero. It makes 10.9 and 10.9.0 one version.
    private func number(at position: Int) -> Int {
        position < numbers.count ? numbers[position] : 0
    }

    private static func positions(_ lhs: ServerVersion, _ rhs: ServerVersion) -> Range<Int> {
        0..<max(lhs.numbers.count, rhs.numbers.count)
    }

    public static func == (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        positions(lhs, rhs).allSatisfy { lhs.number(at: $0) == rhs.number(at: $0) }
    }

    public static func < (lhs: ServerVersion, rhs: ServerVersion) -> Bool {
        for position in positions(lhs, rhs) where lhs.number(at: position) != rhs.number(at: position) {
            return lhs.number(at: position) < rhs.number(at: position)
        }
        return false
    }
}
