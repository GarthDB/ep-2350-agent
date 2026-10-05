import Foundation

struct AppBuildInfo: Equatable {
    let version: String
    let buildNumber: String
    let buildDate: Date?

    static var current: AppBuildInfo {
        let bundle = Bundle.main
        let buildDate = bundle.executableURL.flatMap { executableURL in
            try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }

        return AppBuildInfo(
            version: bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unavailable",
            buildNumber: bundle.infoDictionary?["CFBundleVersion"] as? String ?? "Unavailable",
            buildDate: buildDate
        )
    }

    var label: String {
        let build = "Version \(version) (Build \(buildNumber))"
        guard let buildDate else { return "\(build) · Build time unavailable" }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "\(build) · Built \(formatter.string(from: buildDate))"
    }
}
