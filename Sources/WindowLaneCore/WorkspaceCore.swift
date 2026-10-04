import Foundation
import CoreGraphics

/// The ordered identities of windows in one workspace. Window titles are not identities.
public struct WorkspaceOrder: Codable, Equatable {
    public static let maximumWindowCount = 6

    public private(set) var ids: [String]
    public private(set) var activeID: String?

    public init(ids: [String] = [], activeID: String? = nil) {
        var seen = Set<String>()
        let normalized = Array(ids.filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(Self.maximumWindowCount))
        self.ids = normalized
        self.activeID = activeID.flatMap { normalized.contains($0) ? $0 : nil } ?? normalized.first
    }

    public mutating func add(_ id: String) throws {
        guard !id.isEmpty else { throw WorkspaceOrderError.emptyIdentifier }
        guard !ids.contains(id) else { throw WorkspaceOrderError.alreadyAdded(id) }
        guard ids.count < Self.maximumWindowCount else { throw WorkspaceOrderError.workspaceFull }
        ids.append(id)
        if activeID == nil { activeID = id }
    }

    public mutating func remove(_ id: String) {
        guard let index = ids.firstIndex(of: id) else { return }
        ids.remove(at: index)
        if activeID == id {
            activeID = ids.isEmpty ? nil : ids[min(index, ids.count - 1)]
        }
    }

    public mutating func select(_ id: String) {
        guard ids.contains(id) else { return }
        activeID = id
    }

    /// Moving past either endpoint stays at the endpoint; the strip never wraps.
    public mutating func step(_ delta: Int) {
        guard let activeID, let current = ids.firstIndex(of: activeID) else { return }
        // Compare against the small available distance before adding, avoiding Int overflow.
        let destination: Int
        if delta > ids.count - 1 - current {
            destination = ids.count - 1
        } else if delta < -current {
            destination = 0
        } else {
            destination = current + delta
        }
        self.activeID = ids[destination]
    }

    /// `to` is the item's final index, rather than a pre-removal insertion offset.
    public mutating func move(from: Int, to: Int) {
        guard ids.indices.contains(from), ids.indices.contains(to), from != to else { return }
        let id = ids.remove(at: from)
        ids.insert(id, at: to)
    }

    private enum CodingKeys: String, CodingKey { case ids, activeID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ids: try values.decode([String].self, forKey: .ids),
            activeID: try values.decodeIfPresent(String.self, forKey: .activeID)
        )
    }
}

public enum WorkspaceOrderError: Error, LocalizedError, Equatable {
    case emptyIdentifier
    case alreadyAdded(String)
    case workspaceFull

    public var errorDescription: String? {
        switch self {
        case .emptyIdentifier:
            return "無法識別這個視窗，請重新選擇。"
        case .alreadyAdded:
            return "這個視窗已在工作區中。"
        case .workspaceFull:
            return "工作區最多可加入六個視窗，請先移除一個。"
        }
    }
}

/// Frames use AppKit's global bottom-left coordinate system, including other displays.
public struct WorkspaceLayout: Equatable {
    public let mainFrame: CGRect
    public let leftPreviewFrame: CGRect
    public let rightPreviewFrame: CGRect
    public let railFrame: CGRect

    public init(visibleFrame: CGRect, mainRatio: CGFloat = 0.84, expanded: Bool = false) {
        let screen = visibleFrame.standardized
        let inset = min(12, min(screen.width, screen.height) / 4)
        let innerWidth = max(0, screen.width - inset * 2)
        let innerHeight = max(0, screen.height - inset * 2)
        let railHeight = min(64, innerHeight)
        let railGap = min(16, max(0, innerHeight - railHeight))
        railFrame = CGRect(x: screen.minX + inset, y: screen.minY + inset,
                           width: innerWidth, height: railHeight)
        let content = CGRect(x: screen.minX + inset, y: railFrame.maxY + railGap,
                             width: innerWidth, height: max(0, innerHeight - railHeight - railGap))

        if expanded {
            mainFrame = content
            leftPreviewFrame = CGRect(x: content.minX, y: content.minY, width: 0, height: content.height)
            rightPreviewFrame = CGRect(x: content.maxX, y: content.minY, width: 0, height: content.height)
        } else {
            let ratio = mainRatio.isFinite ? min(0.9, max(0.8, mainRatio)) : 0.84
            let gap = min(12, content.width / 2)
            let windowsWidth = max(0, content.width - gap * 2)
            let previewWidth = windowsWidth * (1 - ratio) / 2
            leftPreviewFrame = CGRect(x: content.minX, y: content.minY,
                                      width: previewWidth, height: content.height)
            mainFrame = CGRect(x: leftPreviewFrame.maxX + gap, y: content.minY,
                               width: windowsWidth * ratio, height: content.height)
            rightPreviewFrame = CGRect(x: mainFrame.maxX + gap, y: content.minY,
                                       width: previewWidth, height: content.height)
        }
    }

    /// Accessibility uses top-left coordinates relative to the primary display.
    /// Use the primary display's full height, never the selected display's height.
    public static func accessibilityFrame(fromAppKit frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryScreenHeight - frame.maxY,
               width: frame.width, height: frame.height)
    }

    public static func appKitFrame(fromAccessibility frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryScreenHeight - frame.maxY,
               width: frame.width, height: frame.height)
    }
}

/// Original placement is captured only once, so subsequent switches cannot overwrite it.
public struct SavedWindowFrame: Codable, Equatable {
    public let id: String
    public let pid: Int32
    public let appBundleID: String?
    public let title: String
    public let frame: CGRect
    public let wasMinimized: Bool

    public init(id: String, pid: Int32, appBundleID: String?, title: String,
                frame: CGRect, wasMinimized: Bool) {
        self.id = id
        self.pid = pid
        self.appBundleID = appBundleID
        self.title = title
        self.frame = frame
        self.wasMinimized = wasMinimized
    }
}
