import AppKit
import SwiftUI

/// Compile with the production DragTransferRouter.swift. No windows are opened,
/// drag payloads created, system preferences changed or synthetic input posted.
@main struct DragRouterLogicChecks {
    @MainActor static func main() {
        var failures: [String] = []
        var passed = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() { passed += 1; print("PASS \(name)") }
            else { failures.append(name); print("FAIL \(name)") }
        }
        var enabled = true
        var available = true
        var directions: [Int] = []
        var activeStates: [Bool] = []
        let router = DragTransferRouter(
            isEnabled: { enabled }, canNavigate: { _ in available },
            navigate: { directions.append($0) },
            onDragStateChanged: { activeStates.append($0) })

        router.updateHover(sequence: 1, direction: 1, now: 10)
        check("enter marks native drag active", router.isDragging && activeStates == [true])
        router.updateHover(sequence: 1, direction: 1, now: 10.449)
        check("short accidental edge visit does not navigate", directions.isEmpty)
        router.updateHover(sequence: 1, direction: 1, now: 10.451)
        check("dwell opens requested neighbor", directions == [1])
        router.updateHover(sequence: 1, direction: 1, now: 13)
        check("stationary pointer cannot repeatedly navigate", directions == [1])

        enabled = false
        router.updateHover(sequence: 1, direction: 1, now: 14)
        enabled = true
        router.updateHover(sequence: 1, direction: 1, now: 15)
        check("temporary operation busy does not unlatch visit", directions == [1])
        router.endHover(sequence: 1, direction: 1)
        check("return to real window retains native drag state", router.isDragging && router.hoverDirection == nil)
        router.updateHover(sequence: 1, direction: 1, now: 16)
        check("reentry starts another dwell rather than immediate turn", directions == [1])
        router.updateHover(sequence: 1, direction: 1, now: 16.46)
        check("leaving and revisiting permits another neighbor", directions == [1, 1])

        router.updateHover(sequence: 1, direction: -1, now: 17)
        router.endHover(sequence: 1, direction: 1)
        router.updateHover(sequence: 1, direction: -1, now: 17.46)
        check("old edge exit cannot clear opposite edge", directions == [1, 1, -1])
        router.endDrag(sequence: 0)
        check("old session end cannot cancel current session", router.isDragging)
        router.endDrag(sequence: 1)
        check("native drag end clears state", !router.isDragging && activeStates == [true, false])

        router.updateHover(sequence: 2, direction: 1, now: 20)
        router.cancel()
        check("workspace stop clears pending hover synchronously", !router.isDragging && router.hoverDirection == nil)
        enabled = false
        router.updateHover(sequence: 2, direction: 1, now: 21)
        check("stale update after stop cannot navigate", directions.count == 3 && !router.isDragging)
        enabled = true
        router.updateHover(sequence: 3, direction: 1, now: 30)
        router.updateHover(sequence: 4, direction: 1, now: 30.4)
        router.updateHover(sequence: 4, direction: 1, now: 30.6)
        check("new source session never inherits old dwell", directions.count == 3)
        router.updateHover(sequence: 4, direction: 1, now: 30.86)
        check("new session can navigate after its own dwell", directions.count == 4)

        router.cancel()
        available = false
        router.updateHover(sequence: 5, direction: 1, now: 40)
        router.updateHover(sequence: 5, direction: 1, now: 41)
        check("missing neighbor cannot start or turn", !router.isDragging && directions.count == 4)
        available = true
        router.updateHover(sequence: 5, direction: 1, now: 42)
        router.updateHover(sequence: 5, direction: 1, now: 41)
        router.updateHover(sequence: 5, direction: 1, now: .nan)
        router.updateHover(sequence: 5, direction: 0, now: 44)
        check("invalid direction or time cannot navigate", directions.count == 4)
        router.cancel()
        check("diagnostic count matches actual callbacks", router.navigationCount == directions.count)

        print("DRAG_ROUTER_LOGIC \(passed)/\(passed + failures.count)")
        if !failures.isEmpty { exit(1) }
    }
}
