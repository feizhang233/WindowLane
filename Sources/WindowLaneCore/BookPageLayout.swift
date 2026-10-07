import Foundation
import CoreGraphics

/// A fractional page position leaves two real windows available for native input.
public struct BookPageLayout: Equatable {
    public let position: Double
    public let bookFrame: CGRect
    public let frames: [Int: CGRect]
    public let leftIndex: Int
    public let rightIndex: Int?
    public var isSplit: Bool { rightIndex != nil }
    public let fitsMinimumWidths: Bool

    public init(visibleFrame: CGRect, mainRatio: CGFloat = 0.84, position: Double,
                count: Int, minimumPaneWidth: CGFloat = 320, minimumWidths: [Int: CGFloat] = [:]) {
        let normal = WorkspaceLayout(visibleFrame: visibleFrame, mainRatio: mainRatio)
        bookFrame = WorkspaceLayout(visibleFrame: visibleFrame, expanded: true).mainFrame
        let bounded = position.isFinite ? min(Double(max(0, count - 1)), max(0, position)) : 0
        let fraction = bounded - floor(bounded)
        let index = Int(floor(bounded))
        if count == 0 {
            self.position = 0; leftIndex = 0; rightIndex = nil; frames = [:]; fitsMinimumWidths = true
        } else if fraction < 0.002 || fraction > 0.998 {
            let single = min(count - 1, Int(bounded.rounded()))
            self.position = Double(single); leftIndex = single; rightIndex = nil
            frames = [single: normal.mainFrame]; fitsMinimumWidths = true
        } else {
            self.position = bounded; leftIndex = index; rightIndex = index + 1
            let gap = min(12, bookFrame.width / 8)
            let width = max(0, bookFrame.width - gap)
            let ratio = mainRatio.isFinite ? min(0.9, max(0.8, mainRatio)) : 0.84
            let minimum = minimumPaneWidth.isFinite ? min(width / 2, max(0, minimumPaneWidth)) : 320
            // Each original application can enforce a different minimum width.
            // Retain the chosen fraction, constraining only its real pane boundary.
            func requiredWidth(_ index: Int) -> CGFloat {
                guard let value = minimumWidths[index], value.isFinite else { return minimum }
                return max(minimum, value)
            }
            let leftMinimum = requiredWidth(index)
            let rightMinimum = requiredWidth(index + 1)
            fitsMinimumWidths = leftMinimum + rightMinimum <= width
            let leftWidth = fitsMinimumWidths
                ? min(width - rightMinimum, max(leftMinimum, width * (ratio - (2 * ratio - 1) * fraction)))
                : min(width - minimum, max(minimum, width / 2))
            frames = [index: CGRect(x: bookFrame.minX, y: bookFrame.minY, width: leftWidth, height: bookFrame.height),
                      index + 1: CGRect(x: bookFrame.minX + leftWidth + gap, y: bookFrame.minY,
                                        width: width - leftWidth, height: bookFrame.height)]
        }
    }
}
