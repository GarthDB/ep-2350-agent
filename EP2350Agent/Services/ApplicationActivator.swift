import AppKit
import EP2350Core

enum ActivationError: Error, LocalizedError {
    case notRunning(String), ambiguous(String), refused(String), timedOut(String), terminated(String)

    var errorDescription: String? {
        switch self {
        case .notRunning(let name): "\(name) is not running. Open it yourself before sending output."
        case .ambiguous(let name): "More than one \(name) process is running. Output was blocked rather than choosing one."
        case .refused(let name): "macOS could not activate \(name). No output was sent."
        case .timedOut(let name): "\(name) did not become the focused app in time. No output was sent."
        case .terminated(let name): "\(name) exited or restarted while being activated. No output was sent."
        }
    }
}

@MainActor
protocol ApplicationActivating {
    func activate(_ target: TargetApplication, permitted: @escaping @MainActor () -> Bool) async throws -> AppIdentity
}

@MainActor
final class ApplicationActivator: ApplicationActivating {
    private let running: @MainActor (String) -> [AppIdentity]
    private let isRunning: @MainActor (AppIdentity) -> Bool
    private let frontmost: @MainActor () -> AppIdentity?
    private let requestActivation: @MainActor (AppIdentity) -> Bool
    private let timeout: Duration
    private let pollInterval: Duration

    init(
        running: @escaping @MainActor (String) -> [AppIdentity] = ApplicationActivator.runningApps,
        isRunning: @escaping @MainActor (AppIdentity) -> Bool = ApplicationActivator.isRunning,
        frontmost: @escaping @MainActor () -> AppIdentity? = AgentController.currentApp,
        requestActivation: @escaping @MainActor (AppIdentity) -> Bool = ApplicationActivator.requestActivation,
        timeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(20)
    ) {
        self.running = running
        self.isRunning = isRunning
        self.frontmost = frontmost
        self.requestActivation = requestActivation
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    func activate(_ target: TargetApplication, permitted: @escaping @MainActor () -> Bool) async throws -> AppIdentity {
        try Task.checkCancellation()
        guard permitted() else { throw OutputError.blocked }
        let candidates = running(target.bundleID).filter { $0.bundleID == target.bundleID }
        guard !candidates.isEmpty else { throw ActivationError.notRunning(target.name) }
        guard candidates.count == 1, let identity = candidates.first else {
            throw ActivationError.ambiguous(target.name)
        }
        guard isRunning(identity) else { throw ActivationError.terminated(target.name) }
        if frontmost() == identity { return identity }
        guard requestActivation(identity) else { throw ActivationError.refused(target.name) }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            // Yield to workspace activation notifications before establishing a new focus guard.
            try await Task.sleep(for: pollInterval)
            try Task.checkCancellation()
            guard permitted() else { throw OutputError.blocked }
            guard isRunning(identity) else { throw ActivationError.terminated(target.name) }
            guard clock.now < deadline else { throw ActivationError.timedOut(target.name) }
            if frontmost() == identity { return identity }
        }
    }

    private static func runningApps(_ bundleID: String) -> [AppIdentity] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
            .map { AppIdentity(processID: $0.processIdentifier, bundleID: bundleID) }
    }

    private static func isRunning(_ identity: AppIdentity) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: identity.processID) else { return false }
        return !app.isTerminated && app.bundleIdentifier == identity.bundleID
    }

    private static func requestActivation(_ identity: AppIdentity) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: identity.processID),
              !app.isTerminated, app.bundleIdentifier == identity.bundleID else { return false }
        return app.activate(options: [])
    }
}
