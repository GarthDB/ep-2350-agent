import Foundation
import Testing
import EP2350Core
@testable import EP2350Agent

private struct FakeCLI {
    let directory: URL
    let executable: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("fake mw \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appendingPathComponent("fake mw")
        let script = """
        #!/bin/sh
        output=''
        model=''
        language=''
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --output) shift; output="$1" ;;
            --model) shift; model="$1" ;;
            --language) shift; language="$1" ;;
          esac
          shift
        done
        case "$model" in
          fail) printf 'test failure\\n' >&2; exit 3 ;;
          hang) exec /bin/sleep 10 ;;
          missing) exit 0 ;;
          empty) : > "$output"; exit 0 ;;
          verbose) /usr/bin/yes 'diagnostic data' | /usr/bin/head -n 10000 ;;
        esac
        if [ "$language" = 'de' ]; then
          printf 'Hallo\\nWelt' > "$output"
        else
          printf 'Hello\\n世界 👋\\n' > "$output"
        fi
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }
    func configuration(model: String = "", language: String = "") -> Configuration {
        var config = Configuration()
        config.macWhisperPath = executable.path
        config.model = model
        config.language = language
        return config
    }
    func cleanup() throws { try FileManager.default.removeItem(at: directory) }
}

@Test func multilineUnicodeAndSpacedExecutable() async throws {
    let cli = try FakeCLI()
    defer { try? cli.cleanup() }
    let text = try await MacWhisperTranscriber(temporaryRoot: cli.directory).transcribe([0.1, 0.2], configuration: cli.configuration())
    #expect(text == "Hello\n世界 👋")
    let language = try await MacWhisperTranscriber(temporaryRoot: cli.directory).transcribe([0.1], configuration: cli.configuration(language: "de"))
    #expect(language == "Hallo\nWelt")
    #expect(try FileManager.default.contentsOfDirectory(atPath: cli.directory.path) == ["fake mw"])
}

@Test(arguments: ["fail", "empty", "missing"])
func cliErrorsAreVisible(model: String) async throws {
    let cli = try FakeCLI()
    defer { try? cli.cleanup() }
    do {
        _ = try await MacWhisperTranscriber(temporaryRoot: cli.directory).transcribe([0.1], configuration: cli.configuration(model: model))
        Issue.record("Expected transcription error")
    } catch let error as TranscriptionError {
        switch model {
        case "fail":
            if case .failed = error {} else { Issue.record("Expected process failure") }
        case "empty": #expect(error == .empty)
        default: #expect(error == .invalidOutput)
        }
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: cli.directory.path) == ["fake mw"])
}

@Test func diagnosticsCannotBlockProcess() async throws {
    let cli = try FakeCLI()
    defer { try? cli.cleanup() }
    let result = try await MacWhisperTranscriber(timeout: 5).transcribe([0.1], configuration: cli.configuration(model: "verbose"))
    #expect(result == "Hello\n世界 👋")
}

@Test func timeoutAndCancellation() async throws {
    let cli = try FakeCLI()
    defer { try? cli.cleanup() }
    do {
        _ = try await MacWhisperTranscriber(timeout: 0.05, temporaryRoot: cli.directory).transcribe([0.1], configuration: cli.configuration(model: "hang"))
        Issue.record("Expected timeout")
    } catch let error as TranscriptionError { #expect(error == .timedOut) }
    let task = Task {
        try await MacWhisperTranscriber(temporaryRoot: cli.directory).transcribe([0.1], configuration: cli.configuration(model: "hang"))
    }
    try await Task.sleep(for: .milliseconds(100))
    task.cancel()
    do {
        _ = try await task.value
        Issue.record("Expected cancellation")
    } catch is CancellationError {}
    #expect(try FileManager.default.contentsOfDirectory(atPath: cli.directory.path) == ["fake mw"])
}

@Test func unavailableExecutableFails() async throws {
    var configuration = Configuration()
    configuration.macWhisperPath = "/no-such-tinkagent-executable"
    do {
        _ = try await MacWhisperTranscriber().transcribe([0.1], configuration: configuration)
        Issue.record("Expected missing executable error")
    } catch let error as TranscriptionError {
        #expect(error == .unavailable(configuration.macWhisperPath))
    }
}

@Test @MainActor func unicodeChunksPreserveTextAndSurrogates() {
    let text = String(repeating: "Hello 👨‍👩‍👧‍👦 世界 e\u{301} ", count: 20)
    let chunks = ActionRouter.unicodeChunks(text)
    #expect(chunks.allSatisfy { !$0.isEmpty && $0.count <= 20 })
    #expect(chunks.map { String(decoding: $0, as: UTF16.self) }.joined() == text)
}
