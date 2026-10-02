import ApplicationServices
import Testing
import EP2350Core
@testable import EP2350Agent

@Test @MainActor func everyActionHasExpectedEvents() async throws {
    let keys: [ButtonAction: Int64] = [
        .enter: 36, .escape: 53, .doubleEscape: 53, .controlC: 8, .controlD: 2,
        .tab: 48, .shiftTab: 48, .shiftEnter: 36, .up: 126, .down: 125,
        .left: 123, .right: 124, .space: 49, .backspace: 51, .paste: 9
    ]
    let texts: [ButtonAction: String] = [
        .one: "1", .two: "2", .three: "3", .yes: "yes", .continue: "continue",
        .clear: "/clear", .compact: "/compact", .custom: "hello"
    ]
    for action in ButtonAction.allCases {
        var events: [CGEvent] = []
        let router = ActionRouter(permission: { true }, post: { events.append($0) })
        try await router.perform(SlotMapping(action, text: "hello"), permitted: { true })
        let downs = events.filter { $0.type == .keyDown }
        #expect(events.count == downs.count * 2)
        if let key = keys[action] {
            #expect(downs.count == (action == .doubleEscape ? 2 : 1))
            #expect(downs.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == key })
            if [.controlC, .controlD].contains(action) { #expect(downs[0].flags.contains(.maskControl)) }
            if [.shiftTab, .shiftEnter].contains(action) { #expect(downs[0].flags.contains(.maskShift)) }
            if action == .paste { #expect(downs[0].flags.contains(.maskCommand)) }
        } else if let text = texts[action] {
            let submits = ![ButtonAction.one, .two, .three].contains(action)
            #expect(downs.count == (submits ? 2 : 1))
            var units = [UInt16](repeating: 0, count: 20)
            var length = 0
            downs[0].keyboardGetUnicodeString(maxStringLength: 20, actualStringLength: &length, unicodeString: &units)
            #expect(String(decoding: units.prefix(length), as: UTF16.self) == text)
            if submits { #expect(downs.last?.getIntegerValueField(.keyboardEventKeycode) == 36) }
        } else {
            #expect(action == .none)
            #expect(events.isEmpty)
        }
    }
}

@Test @MainActor func outputRechecksFocusAndPermissionBetweenChunks() async throws {
    var events: [CGEvent] = []
    let router = ActionRouter(permission: { true }, post: { events.append($0) })
    do {
        try await router.type(String(repeating: "a", count: 100), permitted: { events.count < 2 })
        Issue.record("Expected focus block")
    } catch OutputError.blocked {}
    #expect(events.count == 2)
    events = []
    let deniedRouter = ActionRouter(permission: { false }, post: { events.append($0) })
    do {
        try await deniedRouter.perform(.init(.enter), permitted: { true })
        Issue.record("Expected permission error")
    } catch OutputError.permission {}
    #expect(events.isEmpty)
}

@Test @MainActor func speechNeverSubmitsAndConcurrentKeysAreRejected() async throws {
    var events: [CGEvent] = []
    let router = ActionRouter(permission: { true }, post: { events.append($0) })
    let insertion = Task { try await router.type(String(repeating: "a", count: 100), permitted: { true }) }
    try await Task.sleep(for: .milliseconds(1))
    do {
        try await router.perform(.init(.enter), permitted: { true })
        Issue.record("Expected busy error")
    } catch OutputError.busy {}
    try await insertion.value
    #expect(!events.contains { $0.getIntegerValueField(.keyboardEventKeycode) == 36 })
}
