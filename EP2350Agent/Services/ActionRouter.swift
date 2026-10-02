import AppKit
@preconcurrency import ApplicationServices
import EP2350Core

enum OutputError: Error, LocalizedError {
    case permission, event, blocked, busy
    var errorDescription: String? {
        switch self {
        case .permission: "Enable Accessibility for EP-2350 Agent in System Settings before sending keys."
        case .event: "macOS could not create a keyboard event."
        case .blocked: "Output blocked because the target app, focus, or permissions changed."
        case .busy: "Output is still being prepared or inserted. Wait before sending another action."
        }
    }
}

@MainActor
protocol KeyboardSending {
    func perform(_ mapping: SlotMapping, permitted: @escaping @MainActor () -> Bool) async throws
    func type(_ text: String, permitted: @escaping @MainActor () -> Bool) async throws
}

@MainActor
final class ActionRouter: KeyboardSending {
    private let permission: @MainActor () -> Bool
    private let post: @MainActor (CGEvent) -> Void
    private var busy = false

    init(
        permission: @escaping @MainActor () -> Bool = { ActionRouter.accessibilityGranted },
        post: @escaping @MainActor (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    ) {
        self.permission = permission
        self.post = post
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func perform(_ mapping: SlotMapping, permitted: @escaping @MainActor () -> Bool) async throws {
        if mapping.action == .none { return }
        guard !busy else { throw OutputError.busy }
        busy = true
        defer { busy = false }
        switch mapping.action {
        case .none: return
        case .enter: try key(36, permitted: permitted)
        case .escape: try key(53, permitted: permitted)
        case .doubleEscape:
            try key(53, permitted: permitted)
            try await Task.sleep(for: .milliseconds(50))
            try key(53, permitted: permitted)
        case .controlC: try key(8, flags: .maskControl, permitted: permitted)
        case .controlD: try key(2, flags: .maskControl, permitted: permitted)
        case .tab: try key(48, permitted: permitted)
        case .shiftTab: try key(48, flags: .maskShift, permitted: permitted)
        case .shiftEnter: try key(36, flags: .maskShift, permitted: permitted)
        case .up: try key(126, permitted: permitted)
        case .down: try key(125, permitted: permitted)
        case .left: try key(123, permitted: permitted)
        case .right: try key(124, permitted: permitted)
        case .space: try key(49, permitted: permitted)
        case .backspace: try key(51, permitted: permitted)
        case .paste: try key(9, flags: .maskCommand, permitted: permitted)
        case .one: try await typeChunks("1", permitted: permitted)
        case .two: try await typeChunks("2", permitted: permitted)
        case .three: try await typeChunks("3", permitted: permitted)
        case .yes: try await macro("yes", permitted: permitted)
        case .continue: try await macro("continue", permitted: permitted)
        case .clear: try await macro("/clear", permitted: permitted)
        case .compact: try await macro("/compact", permitted: permitted)
        case .custom: try await macro(mapping.text, permitted: permitted)
        }
    }

    private func macro(_ text: String, permitted: @escaping @MainActor () -> Bool) async throws {
        try await typeChunks(text, permitted: permitted)
        try key(36, permitted: permitted)
    }

    private func key(_ code: CGKeyCode, flags: CGEventFlags = [], permitted: () -> Bool) throws {
        guard permission() else { throw OutputError.permission }
        guard permitted() else { throw OutputError.blocked }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw OutputError.event }
        down.flags = flags
        up.flags = flags
        post(down)
        post(up)
    }

    static func unicodeChunks(_ text: String) -> [[UInt16]] {
        var chunks: [[UInt16]] = []
        var current: [UInt16] = []
        for character in text {
            let units = Array(String(character).utf16)
            if units.count > 20 {
                // Oversize graphemes must be split; keep each surrogate pair intact.
                if !current.isEmpty { chunks.append(current); current = [] }
                for scalar in character.unicodeScalars { chunks.append(Array(String(scalar).utf16)) }
            } else {
                if current.count + units.count > 20 { chunks.append(current); current = [] }
                current += units
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    func type(_ text: String, permitted: @escaping @MainActor () -> Bool) async throws {
        guard !busy else { throw OutputError.busy }
        busy = true
        defer { busy = false }
        try await typeChunks(text, permitted: permitted)
    }

    private func typeChunks(_ text: String, permitted: @escaping @MainActor () -> Bool) async throws {
        guard permission() else { throw OutputError.permission }
        for units in Self.unicodeChunks(text) {
            try Task.checkCancellation()
            guard permission() else { throw OutputError.permission }
            guard permitted() else { throw OutputError.blocked }
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { throw OutputError.event }
            units.withUnsafeBufferPointer { pointer in
                if let base = pointer.baseAddress {
                    down.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: base)
                    up.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: base)
                }
            }
            down.flags = []
            up.flags = []
            post(down)
            post(up)
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
