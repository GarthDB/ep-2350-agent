import Foundation
import Testing
import EP2350Core
@testable import EP2350Agent

@Test @MainActor func ambiguousTargetProcessesAreNeverSelected() async throws {
    let target = TargetApplication(bundleID: "com.example.target", name: "Target")
    let identities = [1, 2].map { AppIdentity(processID: Int32($0), bundleID: target.bundleID) }
    var requests = 0
    let activator = ApplicationActivator(
        running: { _ in identities }, isRunning: { _ in true }, frontmost: { nil },
        requestActivation: { _ in requests += 1; return true }
    )
    await #expect(throws: ActivationError.self) { try await activator.activate(target, permitted: { true }) }
    #expect(requests == 0)
}

@Test @MainActor func sameBundleDifferentProcessIsNotActivationConfirmation() async throws {
    let target = TargetApplication(bundleID: "com.example.target", name: "Target")
    let identity = AppIdentity(processID: 1, bundleID: target.bundleID)
    let replacement = AppIdentity(processID: 2, bundleID: target.bundleID)
    var requests = 0
    let activator = ApplicationActivator(
        running: { _ in [identity] }, isRunning: { _ in true }, frontmost: { replacement },
        requestActivation: { _ in requests += 1; return true },
        timeout: .milliseconds(20), pollInterval: .milliseconds(2)
    )
    await #expect(throws: ActivationError.self) { try await activator.activate(target, permitted: { true }) }
    #expect(requests == 1)
}

@Test @MainActor func permissionGuardRunsBeforeResolvingOrActivatingTarget() async throws {
    var resolved = false
    var requested = false
    let activator = ApplicationActivator(
        running: { _ in resolved = true; return [] }, isRunning: { _ in true }, frontmost: { nil },
        requestActivation: { _ in requested = true; return true }
    )
    let target = TargetApplication(bundleID: "com.example.target", name: "Target")
    await #expect(throws: OutputError.self) { try await activator.activate(target, permitted: { false }) }
    #expect(!resolved)
    #expect(!requested)
}
