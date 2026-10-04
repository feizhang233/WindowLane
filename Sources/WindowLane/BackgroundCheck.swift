import AppKit
import ImageIO
import UniformTypeIdentifiers

private struct BackgroundCheckResult: Encodable {
    let name: String
    let passed: Bool
}
private struct BackgroundReport: Encodable {
    let scope = "local-background-preferences"
    let completedAt: Date
    let passed: Bool
    let checks: [BackgroundCheckResult]
}

/// Explicit test mode uses an isolated preference domain and temporary image storage.
@MainActor func runBackgroundCheck() async -> Bool {
    let arguments = CommandLine.arguments
    func option(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
    let reportURL = URL(fileURLWithPath: option("--report-path") ?? "/tmp/WindowLane-background.json")
    let suite = "WindowLane.background-test.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else { return false }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    var checks: [BackgroundCheckResult] = []
    func record(_ name: String, _ passed: Bool) { checks.append(.init(name: name, passed: passed)) }
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = directory.appendingPathComponent("cache")
        let source = directory.appendingPathComponent("test-wallpaper.png")
        let sourceData = try backgroundFixture()
        try sourceData.write(to: source)
        if let fixturePath = option("--wallpaper-fixture-path") {
            try sourceData.write(to: URL(fileURLWithPath: fixturePath), options: .atomic)
        }
        let settings = BackgroundSettings(defaults: defaults, storageDirectory: cache)
        record("default_is_semitransparent_frosted", settings.mode == .frosted && settings.transparency == 0.35 && settings.settingsTransparency == 0.35)
        record("wallpaper_requires_image", { settings.setMode(.wallpaper); return settings.mode == .frosted }())
        let imported = await settings.importWallpaper(from: source)
        record("valid_image_imported_and_selected", imported && settings.mode == .wallpaper && settings.image != nil)
        record("original_file_unchanged", (try Data(contentsOf: source)) == sourceData)
        record("local_copy_bounded_to_4096_pixels", settings.image.map { $0.size.width <= 4096 && $0.size.height <= 4096 } == true)
        settings.setTransparency(0.52); settings.setSettingsTransparency(0.68); settings.setBlur(17)
        let restored = BackgroundSettings(defaults: defaults, storageDirectory: cache)
        record("image_and_settings_survive_reload", restored.mode == .wallpaper && restored.imageName == source.lastPathComponent && restored.image != nil && restored.transparency == 0.52 && restored.settingsTransparency == 0.68 && restored.blur == 17)
        settings.setSettingsTransparency(0.14)
        record("settings_transparency_does_not_change_application", settings.settingsTransparency == 0.14 && settings.transparency == 0.52)
        settings.setTransparency(0.62)
        record("application_transparency_does_not_change_settings", settings.transparency == 0.62 && settings.settingsTransparency == 0.14)
        settings.setTransparency(0.52); settings.setSettingsTransparency(0.68)
        if let currentData = defaults.data(forKey: BackgroundSettings.defaultsKey),
           var legacyObject = try JSONSerialization.jsonObject(with: currentData) as? [String: Any] {
            legacyObject.removeValue(forKey: "settingsTransparency")
            defaults.set(try JSONSerialization.data(withJSONObject: legacyObject), forKey: BackgroundSettings.defaultsKey)
            let legacy = BackgroundSettings(defaults: defaults, storageDirectory: cache)
            record("legacy_v1_keeps_wallpaper_and_application_transparency", legacy.mode == .wallpaper && legacy.imageName == source.lastPathComponent && legacy.image != nil && legacy.transparency == 0.52 && legacy.blur == 17 && legacy.settingsTransparency == 0.35)
            legacy.setSettingsTransparency(0.44)
            let migrated = BackgroundSettings(defaults: defaults, storageDirectory: cache)
            record("legacy_v1_persists_independent_settings_transparency", migrated.settingsTransparency == 0.44 && migrated.transparency == 0.52 && migrated.mode == .wallpaper)
            legacyObject["transparency"] = 2.0
            legacyObject["settingsTransparency"] = -1.0
            defaults.set(try JSONSerialization.data(withJSONObject: legacyObject), forKey: BackgroundSettings.defaultsKey)
            let bounded = BackgroundSettings(defaults: defaults, storageDirectory: cache)
            record("stored_transparency_values_are_bounded", bounded.transparency == 0.8 && bounded.settingsTransparency == 0)
            defaults.set(currentData, forKey: BackgroundSettings.defaultsKey)
        } else { record("legacy_v1_fixture_created", false) }
        let invalid = directory.appendingPathComponent("invalid.png")
        try Data("not an image".utf8).write(to: invalid)
        let previous = settings.image
        let rejected = await settings.importWallpaper(from: invalid)
        record("invalid_import_keeps_previous_background", !rejected && settings.isError && settings.mode == .wallpaper && settings.image === previous && settings.imageName == source.lastPathComponent)
        try FileManager.default.removeItem(at: source)
        let movedSource = BackgroundSettings(defaults: defaults, storageDirectory: cache)
        record("wallpaper_independent_of_source_path", movedSource.mode == .wallpaper && movedSource.image != nil)
        settings.setTransparency(10); settings.setSettingsTransparency(-10); settings.setBlur(-10)
        record("slider_values_are_bounded", settings.transparency == 0.8 && settings.settingsTransparency == 0 && settings.blur == 0)
        settings.setSettingsTransparency(10)
        record("settings_transparency_upper_bound", settings.settingsTransparency == 0.8)
        settings.setTransparency(.nan); settings.setSettingsTransparency(.infinity); settings.setBlur(.infinity)
        record("nonfinite_values_revert_to_defaults", settings.transparency == 0.35 && settings.settingsTransparency == 0.35 && settings.blur == 24)
        settings.setTransparency(0.7); settings.setSettingsTransparency(0.1)
        settings.restoreDefault()
        record("reset_defaults_retains_reusable_image", settings.mode == .frosted && settings.transparency == 0.35 && settings.settingsTransparency == 0.35 && settings.blur == 24 && settings.image != nil)
        settings.setMode(.wallpaper)
        try Data("corrupt cache".utf8).write(to: cache.appendingPathComponent("wallpaper.png"), options: .atomic)
        let corrupt = BackgroundSettings(defaults: defaults, storageDirectory: cache)
        record("corrupt_cache_falls_back_to_frosted", corrupt.mode == .frosted && corrupt.image == nil && corrupt.isError)
        _ = await settings.importWallpaper(from: invalid)
        settings.removeWallpaper()
        record("remove_copy_clears_wallpaper_preferences", settings.mode == .frosted && settings.image == nil && settings.imageName == nil && !FileManager.default.fileExists(atPath: cache.appendingPathComponent("wallpaper.png").path))
        let interaction = InteractionSettings(defaults:defaults)
        interaction.setHorizontalSwitchingEnabled(false)
        interaction.setScrollThreshold(125); interaction.setScrollScope(.rail)
        let reloadedInteraction = InteractionSettings(defaults:defaults)
        record("scroll_preferences_survive_reload", !reloadedInteraction.horizontalSwitchingEnabled && reloadedInteraction.scrollThreshold == 125 && reloadedInteraction.scrollScope == .rail)
        interaction.setScrollThreshold(-1)
        let lowerBounded = interaction.scrollThreshold == 30
        interaction.setScrollThreshold(999)
        record("scroll_preference_bounds_survive_reload", lowerBounded && InteractionSettings(defaults:defaults).scrollThreshold == 180)
        interaction.setScrollThreshold(.nan)
        let nanBounded = interaction.scrollThreshold == 80
        interaction.setScrollThreshold(.infinity)
        record("scroll_preference_nonfinite_falls_back", nanBounded && InteractionSettings(defaults:defaults).scrollThreshold == 80)
        interaction.setScrollThreshold(125)
        if let saved = defaults.data(forKey:InteractionSettings.defaultsKey),
           var object = try JSONSerialization.jsonObject(with:saved) as? [String:Any] {
            object["scrollScope"] = "future"
            defaults.set(try JSONSerialization.data(withJSONObject:object),forKey:InteractionSettings.defaultsKey)
            let unknownScope = InteractionSettings(defaults:defaults)
            record("unknown_scroll_scope_keeps_other_preferences", unknownScope.scrollScope == .workspace && !unknownScope.horizontalSwitchingEnabled && unknownScope.scrollThreshold == 125)
        } else { record("unknown_scroll_scope_fixture",false) }
    } catch { record("test_fixture_and_storage", false); print(error.localizedDescription) }
    let passed = !checks.isEmpty && checks.allSatisfy(\.passed)
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(BackgroundReport(completedAt: Date(), passed: passed, checks: checks)).write(to: reportURL, options: .atomic)
    } catch { print("Cannot write background report: \(error.localizedDescription)"); return false }
    return passed
}

private func backgroundFixture() throws -> Data {
    // An app-generated test pattern, never a user photograph or document.
    guard let context = CGContext(data: nil, width: 4800, height: 800, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
          let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [NSColor.systemTeal.cgColor, NSColor.systemBlue.cgColor, NSColor.systemOrange.cgColor] as CFArray, locations: [0, 0.5, 1]) else { throw CocoaError(.fileWriteUnknown) }
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 4800, y: 800), options: [])
    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let data = NSMutableData()
    guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}
