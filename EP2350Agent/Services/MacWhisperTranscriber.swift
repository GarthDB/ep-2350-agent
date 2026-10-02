import Foundation
import Darwin
import EP2350Core

enum TranscriptionError: Error, LocalizedError, Equatable {
    case unavailable(String), failed(String), timedOut, empty, invalidOutput
    var errorDescription: String? {
        switch self {
        case .unavailable(let path): "MacWhisper CLI is not executable at \(path). Choose its bundled mw executable in Settings."
        case .failed(let message): "MacWhisper failed: \(message)"
        case .timedOut: "MacWhisper did not finish within the transcription timeout."
        case .empty: "MacWhisper returned an empty transcript."
        case .invalidOutput: "MacWhisper did not produce a valid UTF-8 transcript file."
        }
    }
}

protocol Transcribing: Sendable {
    func transcribe(_ samples: [Float], configuration: Configuration) async throws -> String
}

struct MacWhisperTranscriber: Transcribing {
    var timeout: TimeInterval = 120
    var temporaryRoot = FileManager.default.temporaryDirectory

    func transcribe(_ samples: [Float], configuration: Configuration) async throws -> String {
        try configuration.validate()
        guard FileManager.default.isExecutableFile(atPath: configuration.macWhisperPath) else {
            throw TranscriptionError.unavailable(configuration.macWhisperPath)
        }
        let runner = ProcessRunner()
        let duration = timeout
        let root = temporaryRoot
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached(priority: .userInitiated) {
                let directory = root
                    .appendingPathComponent("EP2350Agent-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer {
                    do { try FileManager.default.removeItem(at: directory) }
                    catch { NSLog("EP2350Agent: temporary transcription cleanup failed: %@", error.localizedDescription) }
                }
                let audio = directory.appendingPathComponent("utterance.wav")
                let output = directory.appendingPathComponent("transcript.txt")
                try WAVEncoder.encode(samples).write(to: audio)
                var arguments = [
                    "transcribe", audio.path, "--format", "txt",
                    "--no-timestamps", "--no-speaker-names", "--no-speakers",
                    "--output", output.path
                ]
                if !configuration.model.isEmpty { arguments += ["--model", configuration.model] }
                if !configuration.language.isEmpty { arguments += ["--language", configuration.language] }
                try runner.run(executable: configuration.macWhisperPath, arguments: arguments, timeout: duration)
                guard let data = try? Data(contentsOf: output), let text = String(data: data, encoding: .utf8) else {
                    throw TranscriptionError.invalidOutput
                }
                let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcript.isEmpty else { throw TranscriptionError.empty }
                guard transcript.utf8.count <= 1_048_576 else {
                    throw TranscriptionError.failed("Transcript exceeds the 1 MB safety limit.")
                }
                return transcript
            }.value
        } onCancel: {
            runner.cancel()
        }
    }
}

private final class Diagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk.prefix(max(0, 32_768 - data.count)))
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var expired = false

    func cancel() {
        stop(timedOut: false)
    }

    private func stop(timedOut: Bool) {
        lock.lock()
        if timedOut { expired = true } else { cancelled = true }
        let child = process
        if let child, child.isRunning { child.terminate() }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if let child = self.process, child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    func run(executable: String, arguments: [String], timeout: TimeInterval) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        let pipe = Pipe()
        let diagnostics = Diagnostics()
        child.standardOutput = pipe
        child.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { diagnostics.append(data) }
        }
        defer {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        process = child
        do { try child.run() }
        catch {
            process = nil
            lock.unlock()
            throw TranscriptionError.failed(error.localizedDescription)
        }
        lock.unlock()
        let timer = DispatchWorkItem { [weak self] in self?.stop(timedOut: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        child.waitUntilExit()
        timer.cancel()
        lock.lock()
        let wasCancelled = cancelled
        let wasExpired = expired
        process = nil
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        if wasExpired { throw TranscriptionError.timedOut }
        guard child.terminationStatus == 0 else {
            throw TranscriptionError.failed(diagnostics.text.isEmpty ? "Exit status \(child.terminationStatus)." : diagnostics.text)
        }
    }
}
