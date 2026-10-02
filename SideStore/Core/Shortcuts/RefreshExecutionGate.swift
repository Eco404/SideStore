import Foundation

/// Ordinary pipelines may retain their existing concurrency. Staged operations
/// reserve exclusive access so cached identity checks cannot race a reinstall.
final class RefreshExecutionGate: @unchecked Sendable {
    static let shared = RefreshExecutionGate()
    private let lock = NSLock()
    private var ordinaryCount = 0
    private var staged = false

    func beginOrdinary() -> Bool {
        lock.withLock {
            guard !staged else { return false }
            ordinaryCount += 1
            return true
        }
    }

    func endOrdinary() {
        lock.withLock { ordinaryCount -= 1 }
    }

    func beginStaged() -> Bool {
        lock.withLock {
            guard !staged, ordinaryCount == 0 else { return false }
            staged = true
            return true
        }
    }

    func endStaged() {
        lock.withLock { staged = false }
    }
}
