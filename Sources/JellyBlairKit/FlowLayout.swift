import SwiftUI

/// Lays out subviews like wrapping text: left to right, breaking into a new
/// line when the width runs out. Used where part of a sentence needs its own
/// interactivity, which a single Text cannot provide.
struct FlowLayout: Layout {
    enum Alignment {
        case leading
        case center
    }

    var alignment: Alignment = .leading
    var horizontalSpacing: CGFloat = 4
    var verticalSpacing: CGFloat = 2

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(sizes: [CGSize], maxWidth: CGFloat) -> [Row] {
        var result: [Row] = []
        var current = Row()
        for (index, size) in sizes.enumerated() {
            let added = current.indices.isEmpty ? size.width : size.width + horizontalSpacing
            if !current.indices.isEmpty, current.width + added > maxWidth {
                result.append(current)
                current = Row()
            }
            current.width += current.indices.isEmpty ? size.width : size.width + horizontalSpacing
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty {
            result.append(current)
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let laidOut = rows(sizes: sizes, maxWidth: maxWidth)
        let contentWidth = laidOut.map(\.width).max() ?? 0
        let height = laidOut.map(\.height).reduce(0, +) + verticalSpacing * CGFloat(max(0, laidOut.count - 1))
        return CGSize(width: min(maxWidth, max(contentWidth, proposal.width ?? contentWidth)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let laidOut = rows(sizes: sizes, maxWidth: bounds.width)
        var y = bounds.minY
        for row in laidOut {
            var x = bounds.minX
            if alignment == .center {
                x += (bounds.width - row.width) / 2
            }
            for index in row.indices {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: .unspecified
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }
}
