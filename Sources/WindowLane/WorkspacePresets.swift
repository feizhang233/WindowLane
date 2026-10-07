import Foundation
import Combine
import WindowLaneCore

/// Observable app adapter for the bounded, atomic local preset repository.
@MainActor final class WorkspacePresets: ObservableObject {
    @Published private(set) var items: [WorkspacePreset]
    @Published private(set) var readError: String?
    let url: URL
    private let repository: WorkspacePresetRepository

    init(url: URL? = nil) {
        let destination = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowLane/workspaces.json")
        self.url = destination
        repository = WorkspacePresetRepository(url: destination)
        items = repository.items
        readError = repository.readError
    }

    @discardableResult func save(name: String, windows: [WorkspaceWindowDescriptor],
                                mainRatio: Double = 0.84, displayID: UInt32? = nil,
                                displayName: String = "", activeSlot: Int = 0,
                                pagePosition: Double? = nil, replacing id: UUID? = nil) throws -> WorkspacePreset {
        let preset = try repository.save(name: name, windows: windows, mainRatio: mainRatio,
                                         displayID: displayID, displayName: displayName,
                                         activeSlot: activeSlot, pagePosition: pagePosition, replacing: id)
        publish()
        return preset
    }

    func rename(_ id: UUID, to name: String) throws { try repository.rename(id, to: name); publish() }
    @discardableResult func delete(_ id: UUID) throws -> WorkspacePreset {
        let preset = try repository.delete(id)
        publish()
        return preset
    }
    func restore(_ preset: WorkspacePreset) throws { try repository.restore(preset); publish() }
    func reload() throws {
        do { try repository.reload(); publish() }
        catch { publish(); throw error }
    }
    private func publish() { items = repository.items; readError = repository.readError }
}
