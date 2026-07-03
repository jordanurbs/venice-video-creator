import AppKit

/// Feedback goes to GitHub issues — this open-source build has no cloud inbox.
@MainActor
enum FeedbackReporter {
    private static let newIssuePath = "https://github.com/jordanurbs/venice-video-creator/issues/new"

    static func issueURL(prefill: String = "") -> URL {
        var body = prefill.isEmpty ? "" : prefill + "\n\n"
        body += "---\nApp: \(appVersion)\nmacOS: \(osVersion)"
        var components = URLComponents(string: newIssuePath)!
        components.queryItems = [URLQueryItem(name: "body", value: body)]
        return components.url ?? URL(string: newIssuePath)!
    }

    static func openIssue(prefill: String = "") {
        NSWorkspace.shared.open(issueURL(prefill: prefill))
    }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
