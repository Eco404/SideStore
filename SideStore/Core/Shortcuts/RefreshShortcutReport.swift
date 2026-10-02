import Foundation

/// An operation outcome, not an exception: Shortcuts must be able to run cleanup next.
struct RefreshShortcutItem: Codable, Sendable {
    let bundleIdentifier: String
    let name: String
    let success: Bool
    let message: String
}

struct RefreshShortcutReport: Codable, Sendable {
    let status: String
    let message: String
    let batchIdentifier: String
    let items: [RefreshShortcutItem]

    var succeeded: Bool { status == "success" || status == "no_apps" }
    var succeededCount: Int { items.filter(\.success).count }
    var failedCount: Int { items.filter { !$0.success }.count }

    var details: String {
        items.map { "\($0.name) (\($0.bundleIdentifier)): \($0.success ? "OK" : "Failed") — \($0.message)" }
            .joined(separator: "\n")
    }
}
