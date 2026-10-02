import Foundation

public enum ButtonAction: String, Codable, CaseIterable, Sendable {
    case enter, escape, doubleEscape, controlC, controlD
    case tab, shiftTab, shiftEnter, up, down, left, right
    case space, backspace, paste, one, two, three
    case yes, `continue`, clear, compact, custom, none

    public var label: String {
        switch self {
        case .enter: "Enter"
        case .escape: "Escape"
        case .doubleEscape: "Double Escape"
        case .controlC: "Control-C"
        case .controlD: "Control-D"
        case .tab: "Tab"
        case .shiftTab: "Shift-Tab"
        case .shiftEnter: "Shift-Enter"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .space: "Space"
        case .backspace: "Backspace"
        case .paste: "Paste"
        case .one: "1"
        case .two: "2"
        case .three: "3"
        case .yes: "Send yes"
        case .continue: "Send continue"
        case .clear: "Send /clear"
        case .compact: "Send /compact"
        case .custom: "Custom text + Enter"
        case .none: "No action"
        }
    }
}

public struct SlotMapping: Codable, Equatable, Sendable {
    public var action: ButtonAction
    public var text: String

    public init(_ action: ButtonAction, text: String = "") {
        self.action = action
        self.text = text
    }
}

public enum OutputMode: String, Codable, CaseIterable, Sendable {
    case foreground, fixedTarget

    public var label: String {
        switch self {
        case .foreground: "Foreground app"
        case .fixedTarget: "Fixed target app"
        }
    }
}

public struct TargetApplication: Codable, Equatable, Sendable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public struct Configuration: Codable, Equatable, Sendable {
    public var version = 1
    public var deviceUID: String?
    public var macWhisperPath = "/Applications/MacWhisper.app/Contents/MacOS/mw"
    public var model = ""
    public var language = ""
    public var allowedBundleIDs: [String] = []
    public var outputMode: OutputMode = .foreground
    public var targetApplication: TargetApplication?
    public var slots: [SlotMapping] = [
        .init(.enter), .init(.escape), .init(.controlC), .init(.shiftTab),
        .init(.up), .init(.down), .init(.none), .init(.none)
    ]

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, deviceUID, macWhisperPath, model, language, allowedBundleIDs, slots
        case outputMode, targetApplication
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        deviceUID = try values.decodeIfPresent(String.self, forKey: .deviceUID)
        macWhisperPath = try values.decode(String.self, forKey: .macWhisperPath)
        model = try values.decode(String.self, forKey: .model)
        language = try values.decode(String.self, forKey: .language)
        allowedBundleIDs = try values.decode([String].self, forKey: .allowedBundleIDs)
        slots = try values.decode([SlotMapping].self, forKey: .slots)
        outputMode = try values.contains(.outputMode) ? values.decode(OutputMode.self, forKey: .outputMode) : .foreground
        targetApplication = try values.decodeIfPresent(TargetApplication.self, forKey: .targetApplication)
    }

    public func validate() throws {
        guard version == 1 else { throw ConfigurationError.invalid("Unsupported settings version \(version).") }
        guard slots.count == 8 else { throw ConfigurationError.invalid("Exactly eight action slots are required.") }
        guard macWhisperPath.hasPrefix("/"), !macWhisperPath.contains("\0") else {
            throw ConfigurationError.invalid("Choose an absolute MacWhisper executable path.")
        }
        guard model.count <= 256, language.count <= 32,
              !model.contains("\0"), !language.contains("\0") else {
            throw ConfigurationError.invalid("Invalid transcription model or language.")
        }
        guard Set(allowedBundleIDs).count == allowedBundleIDs.count,
              allowedBundleIDs.allSatisfy({ !$0.isEmpty && $0.contains(".") && !$0.contains(where: \.isWhitespace) }) else {
            throw ConfigurationError.invalid("Allowed apps must have unique, exact bundle identifiers.")
        }
        if let target = targetApplication {
            guard !target.bundleID.isEmpty, target.bundleID.contains("."),
                  !target.bundleID.contains(where: \.isWhitespace), !target.bundleID.contains("\0"),
                  !target.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !target.name.contains("\0") else {
                throw ConfigurationError.invalid("Choose a target application with a valid name and bundle identifier.")
            }
        }
        if outputMode == .fixedTarget {
            guard let target = targetApplication else {
                throw ConfigurationError.invalid("Choose a target application for fixed-target output.")
            }
            guard !["io.github.garthdb.TinkAgent", "com.goodsnooze.MacWhisper"].contains(target.bundleID) else {
                throw ConfigurationError.invalid("EP-2350 Agent and MacWhisper cannot be output targets.")
            }
            guard allowedBundleIDs.isEmpty || allowedBundleIDs.contains(target.bundleID) else {
                throw ConfigurationError.invalid("The fixed target must be included in Allowed apps, or the allowlist must be empty.")
            }
        }
        for slot in slots {
            guard slot.text.count <= 4096, !slot.text.contains("\0"),
                  slot.action != .custom || !slot.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigurationError.invalid("Custom actions need nonempty text (at most 4096 characters).")
            }
        }
    }
}

public enum ConfigurationError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

public struct ConfigurationStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> Configuration {
        guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
        let value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }

    public func save(_ value: Configuration) throws {
        try value.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
