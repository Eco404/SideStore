import Foundation

/// Maps the refresh callback to data. Missing callbacks for individual apps are
/// failures, not implicit successes (the pipeline can skip running apps).
enum RefreshShortcutOutcome {
    private enum Event: Sendable {
        case finished(RefreshShortcutReport)
        case foregroundDeadline
        case cancelledTimer
    }

    /// Foreground continuation is a best-effort request, not a refresh result.
    /// Always wait for the operation to stop writing before allowing Shortcuts to
    /// restore its network settings. A hard system/process termination cannot be
    /// converted into a result by this in-process helper.
    @available(iOS 16.0, tvOS 16.0, macOS 13.0, watchOS 9.0, *)
    static func run(
        foregroundAfter: Duration = .seconds(27),
        operation: @escaping @Sendable () async throws -> RefreshShortcutReport,
        requestForeground: @escaping @Sendable () async throws -> Void,
        foregroundFailure: @escaping @Sendable (Error) async -> Void = { _ in }
    ) async -> RefreshShortcutReport {
        await withTaskGroup(of: Event.self, returning: RefreshShortcutReport.self) { group in
            group.addTask {
                do {
                    return .finished(try await operation())
                } catch {
                    return .finished(failure(error))
                }
            }
            group.addTask {
                do {
                    try await Task.sleep(for: foregroundAfter)
                    return .foregroundDeadline
                } catch {
                    return .cancelledTimer
                }
            }
            for await event in group {
                switch event {
                case .finished(let report):
                    group.cancelAll()
                    return report
                case .foregroundDeadline:
                    do {
                        try await requestForeground()
                    } catch {
                        await foregroundFailure(error)
                    }
                case .cancelledTimer:
                    continue
                }
            }
            return RefreshShortcutReport(status: "failure", message: "The refresh operation ended without a result.", batchIdentifier: "", items: [])
        }
    }

    static func report<Value>(names: [String: String], result: Result<[String: Result<Value, Error>], Error>) -> RefreshShortcutReport {
        switch result {
        case .failure(let error):
            return failure(error, names: names)
        case .success(let results):
            let identifiers = Set(names.keys).union(results.keys).sorted()
            guard !identifiers.isEmpty else {
                return RefreshShortcutReport(status: "no_apps", message: "There are no apps to refresh.", batchIdentifier: "", items: [])
            }
            let items = identifiers.map { identifier -> RefreshShortcutItem in
                let success: Bool
                let message: String
                switch results[identifier] {
                case .success?:
                    success = true
                    message = "Refreshed."
                case .failure(let error)?:
                    success = false
                    message = error.localizedDescription
                case nil:
                    success = false
                    message = "Skipped or not refreshed. The app may still be running."
                }
                return RefreshShortcutItem(bundleIdentifier: identifier, name: names[identifier] ?? identifier, success: success, message: message)
            }
            let succeeded = items.filter(\.success).count
            let status = succeeded == items.count ? "success" : succeeded == 0 ? "failure" : "partial"
            let message = succeeded == items.count
                ? "All \(succeeded) apps have been refreshed."
                : "Refreshed \(succeeded) of \(items.count) apps. See the result details for failures or skipped apps."
            return RefreshShortcutReport(status: status, message: message, batchIdentifier: "", items: items)
        }
    }

    static func failure(_ error: Error, names: [String: String] = [:]) -> RefreshShortcutReport {
        let items = names.keys.sorted().map { identifier in
            RefreshShortcutItem(bundleIdentifier: identifier, name: names[identifier] ?? identifier, success: false, message: error.localizedDescription)
        }
        return RefreshShortcutReport(status: "failure", message: error.localizedDescription, batchIdentifier: "", items: items)
    }

    /// Start either registers exactly one completion or throws before registering it.
    /// Cancellation deliberately does not return early: the caller must not restore
    /// network settings while the underlying operation is still writing profiles.
    static func awaitCompletion<Value>(
        names: [String: String],
        start: @Sendable (_ completion: @escaping @Sendable (Result<[String: Result<Value, Error>], Error>) -> Void) throws -> Void
    ) async -> RefreshShortcutReport {
        await withCheckedContinuation { continuation in
            do {
                try start { result in
                    continuation.resume(returning: report(names: names, result: result))
                }
            } catch {
                continuation.resume(returning: failure(error, names: names))
            }
        }
    }
}
