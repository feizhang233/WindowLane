import AppKit
import Combine
import ImageIO
import UniformTypeIdentifiers

enum LaneBackgroundMode: String, Codable, CaseIterable {
    case frosted, wallpaper
}

private struct SavedBackground: Codable {
    var mode: LaneBackgroundMode
    var transparency: Double
    // Optional on disk so existing v1 preferences keep their accepted wallpaper
    // and application transparency when settings-window preferences are added.
    var settingsTransparency: Double?
    var blur: Double
    var imageName: String?
}

private enum WallpaperError: LocalizedError {
    case unsupported, tooLarge, cannotEncode
    var errorDescription: String? {
        switch self {
        case .unsupported: return "無法讀取這張圖片。請選擇 PNG、JPEG、HEIC 或其他可開啟的圖片。"
        case .tooLarge: return "圖片檔案過大，請選擇小於 128 MB 的圖片。"
        case .cannotEncode: return "無法處理這張圖片，請試用另一張。"
        }
    }
}

/// Only background preferences and a bounded local copy persist; the source is never changed.
@MainActor final class BackgroundSettings: ObservableObject {
    static let defaultsKey = "WindowLane.background.v1"
    static let defaultTransparency = 0.35
    static let defaultSettingsTransparency = 0.35
    static let defaultBlur = 24.0
    @Published private(set) var mode: LaneBackgroundMode = .frosted
    @Published private(set) var transparency = defaultTransparency
    @Published private(set) var settingsTransparency = defaultSettingsTransparency
    @Published private(set) var blur = defaultBlur
    @Published private(set) var image: NSImage?
    @Published private(set) var imageName: String?
    @Published private(set) var isImporting = false
    @Published private(set) var isChoosingWallpaper = false
    @Published private(set) var notice: String?
    @Published private(set) var isError = false
    private let defaults: UserDefaults
    private let storageDirectory: URL
    private var imageURL: URL { storageDirectory.appendingPathComponent("wallpaper.png") }

    init(defaults: UserDefaults = .standard, storageDirectory: URL? = nil) {
        self.defaults = defaults
        self.storageDirectory = storageDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WindowLane")
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode(SavedBackground.self, from: data) else { return }
        transparency = Self.bounded(saved.transparency, range: 0...0.8, fallback: Self.defaultTransparency)
        settingsTransparency = Self.bounded(saved.settingsTransparency ?? Self.defaultSettingsTransparency,
                                           range: 0...0.8, fallback: Self.defaultSettingsTransparency)
        blur = Self.bounded(saved.blur, range: 0...60, fallback: Self.defaultBlur)
        imageName = saved.imageName
        if saved.imageName != nil { image = NSImage(contentsOf: imageURL) }
        if image != nil { mode = saved.mode }
        else if saved.imageName != nil {
            imageName = nil
            notice = "原有壁紙無法讀取，已使用預設毛玻璃。請重新選擇圖片。"
            isError = true
            persist()
        }
    }

    func setMode(_ value: LaneBackgroundMode) {
        guard value != .wallpaper || image != nil else { return }
        mode = value; persist()
    }
    func setTransparency(_ value: Double) {
        transparency = Self.bounded(value, range: 0...0.8, fallback: Self.defaultTransparency); persist()
    }
    func setSettingsTransparency(_ value: Double) {
        settingsTransparency = Self.bounded(value, range: 0...0.8, fallback: Self.defaultSettingsTransparency); persist()
    }
    func setBlur(_ value: Double) {
        blur = Self.bounded(value, range: 0...60, fallback: Self.defaultBlur); persist()
    }
    func restoreDefault() {
        mode = .frosted; transparency = Self.defaultTransparency
        settingsTransparency = Self.defaultSettingsTransparency; blur = Self.defaultBlur
        notice = "已恢復預設毛玻璃。"; isError = false; persist()
    }
    func removeWallpaper() {
        do {
            if FileManager.default.fileExists(atPath: imageURL.path) { try FileManager.default.removeItem(at: imageURL) }
            image = nil; imageName = nil; mode = .frosted
            notice = "已移除本機壁紙副本，原圖保持完整。"; isError = false; persist()
        } catch { notice = "無法移除壁紙副本：\(error.localizedDescription)"; isError = true }
    }
    func chooseWallpaper() {
        guard !isImporting, !isChoosingWallpaper else { return }
        isChoosingWallpaper = true
        let panel = NSOpenPanel()
        panel.title = "選擇工作區壁紙"
        panel.prompt = "使用圖片"
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                self.isChoosingWallpaper = false
                guard response == .OK, let url = panel.url else { return }
                _ = await self.importWallpaper(from: url)
            }
        }
    }

    @discardableResult func importWallpaper(from url: URL) async -> Bool {
        guard !isImporting else { return false }
        isImporting = true; notice = nil; isError = false
        defer { isImporting = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try Self.prepareWallpaper(url)
            }.value
            guard let decoded = NSImage(data: data) else { throw WallpaperError.unsupported }
            try FileManager.default.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
            try data.write(to: imageURL, options: .atomic)
            image = decoded; imageName = url.lastPathComponent; mode = .wallpaper
            notice = "壁紙已套用，設定會自動保留。"; persist()
            return true
        } catch {
            notice = "\(error.localizedDescription) 原有背景已保留。"; isError = true
            return false
        }
    }

    private func persist() {
        let saved = SavedBackground(mode: mode, transparency: transparency,
                                    settingsTransparency: settingsTransparency, blur: blur, imageName: imageName)
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.defaultsKey) }
    }
    private static func bounded(_ value: Double, range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }
    nonisolated private static func prepareWallpaper(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw WallpaperError.unsupported }
        guard (values.fileSize ?? Int.max) <= 128 * 1024 * 1024 else { throw WallpaperError.tooLarge }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let pixels = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary) else { throw WallpaperError.unsupported }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw WallpaperError.cannotEncode }
        CGImageDestinationAddImage(destination, pixels, nil)
        guard CGImageDestinationFinalize(destination) else { throw WallpaperError.cannotEncode }
        return output as Data
    }
}
