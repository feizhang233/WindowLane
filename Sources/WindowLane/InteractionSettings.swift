import Foundation
import Combine
import WindowLaneCore

enum ScrollSwitchScope: String, Codable, CaseIterable {
    case workspace, rail
}

enum ScrollPagingMode: String, Codable, CaseIterable {
    case stepped, continuous
}

private struct SavedInteractionSettings: Codable {
    var horizontalSwitchingEnabled: Bool
    var scrollThreshold: Double
    var scrollScope: String
    var scrollMode: String?
}

/// Only interaction preferences persist; scroll gesture state always starts fresh.
@MainActor final class InteractionSettings: ObservableObject {
    static let defaultsKey = "WindowLane.interaction.v1"
    static let defaultScrollThreshold = HorizontalScrollGate.defaultThreshold
    @Published private(set) var horizontalSwitchingEnabled = true
    @Published private(set) var scrollThreshold = defaultScrollThreshold
    @Published private(set) var scrollScope: ScrollSwitchScope = .workspace
    @Published private(set) var scrollMode: ScrollPagingMode = .continuous
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let saved = try? JSONDecoder().decode(SavedInteractionSettings.self, from: data) else { return }
        horizontalSwitchingEnabled = saved.horizontalSwitchingEnabled
        scrollThreshold = HorizontalScrollGate.boundedThreshold(saved.scrollThreshold)
        scrollScope = ScrollSwitchScope(rawValue: saved.scrollScope) ?? .workspace
        scrollMode = saved.scrollMode.flatMap(ScrollPagingMode.init(rawValue:)) ?? .continuous
    }

    func setHorizontalSwitchingEnabled(_ value: Bool) {
        horizontalSwitchingEnabled = value
        persist()
    }

    func setScrollThreshold(_ value: Double) {
        scrollThreshold = HorizontalScrollGate.boundedThreshold(value)
        persist()
    }

    func setScrollScope(_ value: ScrollSwitchScope) {
        scrollScope = value
        persist()
    }

    func setScrollMode(_ value: ScrollPagingMode) {
        scrollMode = value
        persist()
    }

    private func persist() {
        let saved = SavedInteractionSettings(
            horizontalSwitchingEnabled: horizontalSwitchingEnabled,
            scrollThreshold: scrollThreshold,
            scrollScope: scrollScope.rawValue,
            scrollMode: scrollMode.rawValue
        )
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
