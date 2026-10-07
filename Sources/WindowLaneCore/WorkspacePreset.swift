import Foundation

/// A saved window selection. The runtime ID alone must never identify a window
/// after an application restarts; session hints or an unambiguous exact title do.
public struct WorkspaceWindowDescriptor: Codable, Equatable, Identifiable {
    public let id: String
    public let bundleIdentifier: String?
    public let appName: String
    public let title: String
    public let processID: Int32?
    public let windowID: UInt32?
    public let launchTime: TimeInterval?
    public let nativeDemoIndex: Int?

    public init(id: String, bundleIdentifier: String? = nil, appName: String, title: String,
                processID: Int32? = nil, windowID: UInt32? = nil,
                launchTime: TimeInterval? = nil, nativeDemoIndex: Int? = nil) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.title = title
        self.processID = processID
        self.windowID = windowID
        self.launchTime = launchTime
        self.nativeDemoIndex = nativeDemoIndex
    }

    public var label: String { title.isEmpty ? appName : "\(appName) — \(title)" }
}

/// Only selection and layout preferences persist. Saving a preset never stores
/// document pixels or grants permission to reopen applications or documents.
public struct WorkspacePreset: Codable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let windows: [WorkspaceWindowDescriptor]
    public let mainRatio: Double
    public let displayID: UInt32?
    public let displayName: String
    public let activeSlot: Int
    public let pagePosition: Double?
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: UUID = UUID(), name: String, windows: [WorkspaceWindowDescriptor],
                mainRatio: Double = 0.84, displayID: UInt32? = nil, displayName: String = "",
                activeSlot: Int = 0, pagePosition: Double? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.windows = windows
        self.mainRatio = mainRatio.isFinite ? min(0.9, max(0.8, mainRatio)) : 0.84
        self.displayID = displayID
        self.displayName = displayName
        let boundedSlot = max(0, min(activeSlot, max(0, windows.count - 1)))
        self.activeSlot = boundedSlot
        self.pagePosition = pagePosition.map {
            $0.isFinite ? min(Double(max(0, windows.count - 1)), max(0, $0)) : Double(boundedSlot)
        }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var effectivePagePosition: Double { pagePosition ?? Double(activeSlot) }

    private enum CodingKeys: String, CodingKey {
        case id, name, windows, mainRatio, displayID, displayName, activeSlot, pagePosition, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try values.decode(UUID.self, forKey: .id),
                  name: try values.decode(String.self, forKey: .name),
                  windows: try values.decode([WorkspaceWindowDescriptor].self, forKey: .windows),
                  mainRatio: try values.decodeIfPresent(Double.self, forKey: .mainRatio) ?? 0.84,
                  displayID: try values.decodeIfPresent(UInt32.self, forKey: .displayID),
                  displayName: try values.decodeIfPresent(String.self, forKey: .displayName) ?? "",
                  activeSlot: try values.decodeIfPresent(Int.self, forKey: .activeSlot) ?? 0,
                  pagePosition: try values.decodeIfPresent(Double.self, forKey: .pagePosition),
                  createdAt: try values.decode(Date.self, forKey: .createdAt),
                  updatedAt: try values.decode(Date.self, forKey: .updatedAt))
    }
}

public enum WorkspacePresetMatchKind: String, Equatable {
    case sameSession, exactTitle, nativeDemo, missing, ambiguous, unidentifiable
}

public struct WorkspacePresetMatch: Equatable {
    public let saved: WorkspaceWindowDescriptor
    public let candidateID: String?
    public let kind: WorkspacePresetMatchKind
}

public struct WorkspacePresetResolution: Equatable {
    public let slots: [WorkspacePresetMatch]
    public var isComplete: Bool { !slots.isEmpty && slots.allSatisfy { $0.candidateID != nil } }
    public var matchedIDs: [String] { slots.compactMap(\.candidateID) }
    public var unresolvedLabels: [String] { slots.filter { $0.candidateID == nil }.map { $0.saved.label } }
}

public enum WorkspacePresetMatcher {
    public static func resolve(_ preset: WorkspacePreset,
                               among candidates: [WorkspaceWindowDescriptor]) -> WorkspacePresetResolution {
        var slots = preset.windows.map { saved -> WorkspacePresetMatch in
            if let index = saved.nativeDemoIndex {
                let demos = candidates.filter { $0.nativeDemoIndex == index }
                return match(saved, candidates: demos, kind: .nativeDemo)
            }
            if let pid = saved.processID, let windowID = saved.windowID,
               let launch = saved.launchTime, launch.isFinite {
                let sameSession = candidates.filter {
                    guard $0.nativeDemoIndex == nil, $0.processID == pid, $0.windowID == windowID,
                          let currentLaunch = $0.launchTime, currentLaunch.isFinite,
                          abs(currentLaunch - launch) < 0.01 else { return false }
                    if let bundle = saved.bundleIdentifier { return $0.bundleIdentifier == bundle }
                    return true
                }
                if !sameSession.isEmpty { return match(saved, candidates: sameSession, kind: .sameSession) }
            }
            guard let bundle = saved.bundleIdentifier, !bundle.isEmpty, !saved.title.isEmpty else {
                return WorkspacePresetMatch(saved: saved, candidateID: nil, kind: .unidentifiable)
            }
            let exactTitle = candidates.filter {
                $0.nativeDemoIndex == nil && $0.bundleIdentifier == bundle && $0.title == saved.title
            }
            return match(saved, candidates: exactTitle, kind: .exactTitle)
        }
        // Two saved slots cannot share one current window, even when each title
        // lookup was individually unique. Keep the entire preset unresolved.
        let claims = Dictionary(grouping: slots.compactMap(\.candidateID), by: { $0 })
        for index in slots.indices {
            if let id = slots[index].candidateID, (claims[id]?.count ?? 0) > 1 {
                slots[index] = WorkspacePresetMatch(saved: slots[index].saved, candidateID: nil, kind: .ambiguous)
            }
        }
        return WorkspacePresetResolution(slots: slots)
    }

    private static func match(_ saved: WorkspaceWindowDescriptor,
                              candidates: [WorkspaceWindowDescriptor], kind: WorkspacePresetMatchKind) -> WorkspacePresetMatch {
        guard candidates.count == 1, let candidate = candidates.first, !candidate.id.isEmpty else {
            return WorkspacePresetMatch(saved: saved, candidateID: nil, kind: candidates.isEmpty ? .missing : .ambiguous)
        }
        return WorkspacePresetMatch(saved: saved, candidateID: candidate.id, kind: kind)
    }
}

public enum WorkspacePresetError: Error, LocalizedError, Equatable {
    case invalidName, duplicateName, noWindows, tooManyWindows, duplicateWindows
    case collectionFull, notFound, invalidArchive, unsupportedVersion, unreadableArchive

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "請輸入 1–80 個字的工作區名稱，不包含換行或控制字元。"
        case .duplicateName: return "已經有同名工作區，請使用另一個名稱或更新原來的工作區。"
        case .noWindows: return "請先加入至少一個視窗，再儲存工作區。"
        case .tooManyWindows: return "一個已儲存工作區最多包含六個視窗。"
        case .duplicateWindows: return "工作區含有無法辨識或重複的視窗，請重新選擇。"
        case .collectionFull: return "最多可儲存 24 個工作區，請先移除不再使用的排版。"
        case .notFound: return "找不到這個已儲存工作區，請重新選擇。"
        case .invalidArchive: return "已儲存工作區的資料不完整，原檔保留，請先修復或還原備份。"
        case .unsupportedVersion: return "這份工作區資料來自較新的版本，原檔保留，請更新 WindowLane。"
        case .unreadableArchive: return "工作區記錄無法讀取，原檔保留，暫時不能覆寫。"
        }
    }
}

/// Synchronous, bounded local storage. The app calls this on its MainActor;
/// a failed decode or write never silently replaces the accepted collection.
public final class WorkspacePresetRepository {
    public static let maximumPresetCount = 24
    public private(set) var items: [WorkspacePreset] = []
    public private(set) var readError: String?
    public let url: URL
    private let now: () -> Date

    public init(url: URL, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
        do { try reload() } catch { readError = error.localizedDescription }
    }

    public func reload() throws {
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                items = []; readError = nil; return
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= 1_048_576 else {
                throw WorkspacePresetError.invalidArchive
            }
            let decoder = JSONDecoder()
            // Foundation's reference-date representation round-trips Date's
            // original precision without an epoch conversion changing equality.
            decoder.dateDecodingStrategy = .deferredToDate
            let archive = try decoder.decode(Archive.self, from: Data(contentsOf: url))
            guard archive.version == 1 else { throw WorkspacePresetError.unsupportedVersion }
            try Self.validate(archive.presets)
            items = archive.presets
            readError = nil
        } catch {
            readError = error.localizedDescription
            throw error
        }
    }

    @discardableResult public func save(name: String, windows: [WorkspaceWindowDescriptor],
                                      mainRatio: Double = 0.84, displayID: UInt32? = nil,
                                      displayName: String = "", activeSlot: Int = 0,
                                      pagePosition: Double? = nil, replacing id: UUID? = nil) throws -> WorkspacePreset {
        try requireReadable()
        let normalizedName = try Self.validName(name)
        if let id, !items.contains(where: { $0.id == id }) { throw WorkspacePresetError.notFound }
        let previous = id.flatMap { id in items.first { $0.id == id } }
        let timestamp = now()
        let preset = WorkspacePreset(id: id ?? UUID(), name: normalizedName, windows: windows,
                                     mainRatio: mainRatio, displayID: displayID, displayName: displayName,
                                     activeSlot: activeSlot, pagePosition: pagePosition,
                                     createdAt: previous?.createdAt ?? timestamp, updatedAt: timestamp)
        var next = items
        if let index = next.firstIndex(where: { $0.id == preset.id }) { next[index] = preset }
        else { next.append(preset) }
        try commit(next)
        return preset
    }

    public func rename(_ id: UUID, to name: String) throws {
        guard let preset = items.first(where: { $0.id == id }) else { throw WorkspacePresetError.notFound }
        try save(name: name, windows: preset.windows, mainRatio: preset.mainRatio,
                 displayID: preset.displayID, displayName: preset.displayName,
                 activeSlot: preset.activeSlot, pagePosition: preset.pagePosition, replacing: id)
    }

    @discardableResult public func delete(_ id: UUID) throws -> WorkspacePreset {
        try requireReadable()
        guard let preset = items.first(where: { $0.id == id }) else { throw WorkspacePresetError.notFound }
        try commit(items.filter { $0.id != id })
        return preset
    }

    public func restore(_ preset: WorkspacePreset) throws {
        try requireReadable()
        guard !items.contains(where: { $0.id == preset.id }) else { throw WorkspacePresetError.duplicateName }
        try commit(items + [preset])
    }

    private func requireReadable() throws {
        guard readError == nil else { throw WorkspacePresetError.unreadableArchive }
    }

    private func commit(_ next: [WorkspacePreset]) throws {
        try Self.validate(next)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate
        let data = try encoder.encode(Archive(version: 1, presets: next))
        guard data.count <= 1_048_576 else { throw WorkspacePresetError.invalidArchive }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        items = next
    }

    private static func validName(_ name: String) throws -> String {
        let result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= 80,
              result.rangeOfCharacter(from: .controlCharacters) == nil else { throw WorkspacePresetError.invalidName }
        return result
    }

    private static func validate(_ presets: [WorkspacePreset]) throws {
        guard presets.count <= maximumPresetCount else { throw WorkspacePresetError.collectionFull }
        guard Set(presets.map(\.id)).count == presets.count else { throw WorkspacePresetError.invalidArchive }
        var names = Set<String>()
        for preset in presets {
            let name = try validName(preset.name)
            guard name == preset.name else { throw WorkspacePresetError.invalidArchive }
            let comparable = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(comparable).inserted else { throw WorkspacePresetError.duplicateName }
            guard !preset.windows.isEmpty else { throw WorkspacePresetError.noWindows }
            guard preset.windows.count <= WorkspaceOrder.maximumWindowCount else { throw WorkspacePresetError.tooManyWindows }
            guard preset.windows.allSatisfy({ !$0.id.isEmpty }),
                  Set(preset.windows.map(\.id)).count == preset.windows.count else { throw WorkspacePresetError.duplicateWindows }
            guard preset.createdAt.timeIntervalSince1970.isFinite,
                  preset.updatedAt.timeIntervalSince1970.isFinite else { throw WorkspacePresetError.invalidArchive }
        }
    }

    private struct Archive: Codable {
        let version: Int
        let presets: [WorkspacePreset]
    }
}
