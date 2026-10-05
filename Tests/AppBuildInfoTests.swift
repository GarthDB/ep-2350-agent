import Foundation
import Testing
@testable import EP2350Agent

@Test func appBuildInfoIncludesVersionBuildAndBuildDate() {
    let info = AppBuildInfo(
        version: "0.1.0",
        buildNumber: "42",
        buildDate: Date(timeIntervalSince1970: 0)
    )

    #expect(info.label == "Version 0.1.0 (Build 42) · Built 1970-01-01T00:00:00.000Z")
}

@Test func appBuildInfoMakesMissingBuildDateExplicit() {
    let info = AppBuildInfo(version: "0.1.0", buildNumber: "42", buildDate: nil)

    #expect(info.label == "Version 0.1.0 (Build 42) · Build time unavailable")
}
