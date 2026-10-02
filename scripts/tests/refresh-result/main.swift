import Foundation

enum TestFailure: Error, LocalizedError {
    case network
    var errorDescription: String? { "Device network is unavailable." }
}

private typealias Completion = @Sendable (Result<[String: Result<Int, Error>], Error>) -> Void

/// Synchronizes registration/completion without sleeps, so cancellation exercises
/// an outstanding production continuation rather than merely an already-done task.
private actor PendingCallback {
    private var completion: Completion?
    private var registeredWaiter: CheckedContinuation<Void, Never>?
    private var returned = false

    func register(_ callback: @escaping Completion) {
        completion = callback
        registeredWaiter?.resume()
        registeredWaiter = nil
    }

    func waitForRegistration() async {
        if completion != nil { return }
        await withCheckedContinuation { registeredWaiter = $0 }
    }

    func complete() {
        precondition(!returned, "Cancelled shortcut returned before writes completed")
        completion?(.failure(CancellationError()))
        completion = nil
    }

    func didReturn() { returned = true }
}

private actor DeadlineProbe {
    private var operationWaiter: CheckedContinuation<Void, Never>?
    private var failureWaiter: CheckedContinuation<Void, Never>?
    private var denied = false
    private var released = false
    private(set) var requested = false
    private(set) var returned = false

    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { operationWaiter = $0 }
    }

    func request() throws {
        requested = true
        throw TestFailure.network
    }

    func noteDenial() {
        denied = true
        failureWaiter?.resume()
        failureWaiter = nil
    }

    func waitForDenial() async {
        if denied { return }
        await withCheckedContinuation { failureWaiter = $0 }
    }

    func release() {
        precondition(!returned, "Foreground denial returned before the operation finished")
        released = true
        operationWaiter?.resume()
        operationWaiter = nil
    }

    func didReturn() { returned = true }
}

@main
struct RefreshResultTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func main() async {
        let names = ["app.a": "App A", "app.b": "App B"]
        let all: Result<[String: Result<Int, Error>], Error> = .success(["app.a": .success(1), "app.b": .success(2)])
        let success = RefreshShortcutOutcome.report(names: names, result: all)
        require(success.succeeded && success.succeededCount == 2 && success.failedCount == 0, "Complete success must retain both apps")

        let mixed: Result<[String: Result<Int, Error>], Error> = .success(["app.a": .success(1), "app.b": .failure(TestFailure.network)])
        let partial = RefreshShortcutOutcome.report(names: names, result: mixed)
        require(partial.status == "partial" && !partial.succeeded, "Partial success must not be reported as full success")
        require(partial.succeededCount == 1 && partial.failedCount == 1 && partial.details.contains("Device network is unavailable."), "Per-app errors must survive aggregation")

        let omitted: Result<[String: Result<Int, Error>], Error> = .success(["app.a": .success(1)])
        let skipped = RefreshShortcutOutcome.report(names: names, result: omitted)
        require(skipped.status == "partial" && skipped.items.last?.bundleIdentifier == "app.b" && skipped.items.last?.success == false, "Omitted requested apps must remain unsuccessful")

        let empty: Result<[String: Result<Int, Error>], Error> = .success([:])
        let missing = RefreshShortcutOutcome.report(names: names, result: empty)
        require(missing.status == "failure" && missing.failedCount == 2, "Empty pipeline callback must not turn outstanding requests into success")
        let noApps = RefreshShortcutOutcome.report(names: [:], result: empty)
        require(noApps.status == "no_apps" && noApps.succeeded && noApps.items.isEmpty, "A genuinely empty request is no_apps")

        let global: Result<[String: Result<Int, Error>], Error> = .failure(TestFailure.network)
        let failed = RefreshShortcutOutcome.report(names: names, result: global)
        require(failed.status == "failure" && failed.failedCount == 2 && failed.message == "Device network is unavailable.", "Global errors must return failure for every requested app")
        let preflight = RefreshShortcutOutcome.failure(TestFailure.network)
        require(!preflight.succeeded && preflight.items.isEmpty && preflight.message == failed.message, "Preflight failure must remain failure without app metadata")

        let unexpected: Result<[String: Result<Int, Error>], Error> = .success(["other.app": .failure(TestFailure.network)])
        let retained = RefreshShortcutOutcome.report(names: [:], result: unexpected)
        require(retained.failedCount == 1 && retained.items[0].name == "other.app", "Callback identifiers without metadata must not be dropped")

        let constructorFailure = await RefreshShortcutOutcome.awaitCompletion(names: names) { (_: @escaping Completion) in
            throw TestFailure.network
        }
        require(constructorFailure.failedCount == 2 && !constructorFailure.succeeded, "Synchronous registration errors must resume instead of hanging")

        let callbackResult = await RefreshShortcutOutcome.awaitCompletion(names: names) { (completion: @escaping Completion) in
            completion(mixed)
        }
        require(callbackResult.status == "partial", "Actual callback adapter must preserve partial results")

        let cancelledResult = await RefreshShortcutOutcome.awaitCompletion(names: names) { (completion: @escaping Completion) in
            completion(.failure(CancellationError()))
        }
        require(!cancelledResult.succeeded && cancelledResult.failedCount == 2, "Cancellation errors must be returned as data")

        let pending = PendingCallback()
        let task = Task {
            let report = await RefreshShortcutOutcome.awaitCompletion(names: names) { (completion: @escaping Completion) in
                Task { await pending.register(completion) }
            }
            await pending.didReturn()
            return report
        }
        await pending.waitForRegistration()
        task.cancel()
        await Task.yield()
        await pending.complete()
        let afterCancellation = await task.value
        require(afterCancellation.status == "failure" && afterCancellation.failedCount == 2, "Cancelled task must still await completion and return the outcome")

        let quickProbe = DeadlineProbe()
        let quick = await RefreshShortcutOutcome.run(foregroundAfter: .seconds(60), operation: {
            success
        }, requestForeground: {
            try await quickProbe.request()
        })
        let requestedForQuick = await quickProbe.requested
        require(quick.succeeded && !requestedForQuick, "Fast refresh must cancel timer and avoid a foreground request")

        let partialResult = await RefreshShortcutOutcome.run(foregroundAfter: .seconds(60), operation: {
            partial
        }, requestForeground: {})
        require(partialResult.status == "partial" && partialResult.failedCount == 1, "Deadline helper must preserve partial outcomes")

        let thrownResult = await RefreshShortcutOutcome.run(foregroundAfter: .seconds(60), operation: {
            throw TestFailure.network
        }, requestForeground: {})
        require(!thrownResult.succeeded && thrownResult.message == failed.message, "Operation errors must be returned rather than escape the helper")

        let deadlineProbe = DeadlineProbe()
        let longOperation = Task {
            let result = await RefreshShortcutOutcome.run(foregroundAfter: .milliseconds(1), operation: {
                await deadlineProbe.waitForRelease()
                return partial
            }, requestForeground: {
                try await deadlineProbe.request()
            }, foregroundFailure: { _ in
                await deadlineProbe.noteDenial()
            })
            await deadlineProbe.didReturn()
            return result
        }
        await deadlineProbe.waitForDenial()
        await Task.yield()
        await deadlineProbe.release()
        let afterDenial = await longOperation.value
        require(afterDenial.status == "partial" && afterDenial.failedCount == 1, "Denied foreground request must await quiescence and return the real operation result")

        print("PASS: 16 refresh result, callback, and foreground deadline scenarios")
    }
}
