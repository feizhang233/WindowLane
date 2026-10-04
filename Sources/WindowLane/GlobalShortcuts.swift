import AppKit
import Carbon

enum ShortcutAction: Equatable, Sendable {
    case previous
    case next
    case select(Int)
    case toggleExpanded
    case stop
    case addFrontmost
    case showManager
}

/// Registers only the app's explicit shortcuts. It does not capture general input.
@MainActor
final class GlobalShortcuts {
    private static let signature: OSType = 0x574C414E // WLAN
    private let handler: (ShortcutAction) -> Void
    private var hotKeys: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?
    private var localMonitor: Any?
    private var actions: [UInt32: ShortcutAction] = [:]
    private var identifiersByKeyCode: [UInt16: UInt32] = [:]
    private var lastDelivery: (identifier: UInt32, time: TimeInterval)?
    private(set) var registrationFailures: [String] = []

    init(handler: @escaping (ShortcutAction) -> Void) {
        self.handler = handler
        register()
    }

    func unregister() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll()
        actions.removeAll()
        identifiersByKeyCode.removeAll()
        lastDelivery = nil
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func register() {
        var bindings: [(ShortcutAction, Int, String)] = [
            (.previous, kVK_LeftArrow, "⌃⌥←"),
            (.next, kVK_RightArrow, "⌃⌥→"),
            (.toggleExpanded, kVK_Return, "⌃⌥↩"),
            (.stop, kVK_Escape, "⌃⌥Esc"),
            (.addFrontmost, kVK_ANSI_A, "⌃⌥A"),
            (.showManager, kVK_Space, "⌃⌥Space")
        ]
        let numberKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6]
        bindings += numberKeys.enumerated().map { (.select($0.offset), $0.element, "⌃⌥\($0.offset + 1)") }
        for (offset, binding) in bindings.enumerated() {
            let identifier = UInt32(offset + 1)
            actions[identifier] = binding.0
            identifiersByKeyCode[UInt16(binding.1)] = identifier
        }

        // Carbon owns the system-wide shortcuts. AppKit's local monitor also handles
        // key events delivered directly to this app (including native UI test input).
        // It never observes another application's ordinary keyboard input.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.contains([.control, .option]),
                  modifiers.intersection([.command, .shift]).isEmpty else { return event }
            let keyCode = event.keyCode
            let consumed = MainActor.assumeIsolated {
                guard let self, let identifier = self.identifiersByKeyCode[keyCode] else { return false }
                self.deliver(identifier)
                return true
            }
            return consumed ? nil : event
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context -> OSStatus in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard result == noErr, hotKeyID.signature == 0x574C414E else {
                    return OSStatus(eventNotHandledErr)
                }
                let owner = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
                let identifier = hotKeyID.id
                Task { @MainActor [weak owner] in
                    owner?.deliver(identifier)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else {
            registrationFailures = ["無法啟用快捷鍵（\(status)）"]
            return
        }

        for (offset, binding) in bindings.enumerated() {
            let identifier = UInt32(offset + 1)
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
            var hotKey: EventHotKeyRef?
            let result = RegisterEventHotKey(
                UInt32(binding.1),
                UInt32(controlKey | optionKey),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKey
            )
            if result == noErr, let hotKey {
                hotKeys.append(hotKey)
            } else {
                registrationFailures.append("\(binding.2) 無法註冊（\(result)），可能已被其他應用使用。")
            }
        }
    }

    private func deliver(_ identifier: UInt32) {
        guard let action = actions[identifier] else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Real Carbon hotkeys normally consume the original key event. Deduplicate
        // defensively if a delivery path nevertheless reaches both handlers.
        if let lastDelivery, lastDelivery.identifier == identifier, now - lastDelivery.time < 0.05 { return }
        lastDelivery = (identifier, now)
        handler(action)
    }
}
