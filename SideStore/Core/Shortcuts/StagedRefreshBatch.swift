import Foundation

struct StagedRefreshIdentity: Codable, Sendable, Equatable {
    let objectURI: String
    let bundleIdentifier: String
    let resignedBundleIdentifier: String
    let version: String
    let buildVersion: String
    let installedDate: Date
    let fingerprint: String?
    let certificateSerial: String
    let extensionIdentifiers: [String]
    let useMainProfile: Bool

    var profileTargets: [String] {
        useMainProfile ? [resignedBundleIdentifier] : [resignedBundleIdentifier] + extensionIdentifiers
    }
}

struct StagedRefreshEntry: Codable, Sendable {
    let identity: StagedRefreshIdentity
    let name: String
    /// Keys are installed (resigned) identifiers, including each extension.
    var profiles: [String: Data]
    var applied: Bool = false
}

struct StagedRefreshBatch: Codable, Sendable {
    var schemaVersion = 1
    let identifier: String
    let createdAt: Date
    let teamIdentifier: String
    let accountIdentifier: String
    let deviceIdentifier: String
    var entries: [StagedRefreshEntry]
    let preparationFailures: [RefreshShortcutItem]

    func validate(team: String, account: String, device: String, now: Date = Date()) throws {
        guard schemaVersion == 1 else { throw StagedRefreshError("Unsupported batch format. Prepare a new batch.") }
        guard teamIdentifier == team, accountIdentifier == account, deviceIdentifier == device else {
            throw StagedRefreshError("Account, team or device changed. Prepare a new batch.")
        }
        guard now.timeIntervalSince(createdAt) >= -60, now.timeIntervalSince(createdAt) < 86_400 else {
            throw StagedRefreshError("This batch is older than 24 hours. Prepare a new batch.")
        }
    }

    mutating func markApplied(bundleIdentifier: String) throws {
        guard let index = entries.firstIndex(where: { $0.identity.bundleIdentifier == bundleIdentifier }) else {
            throw StagedRefreshError("The application is not part of this batch.")
        }
        entries[index].applied = true
        // Keep only a replay tombstone after installation. A partially completed
        // batch retains payloads solely for applications still awaiting a retry.
        entries[index].profiles.removeAll()
    }
}

struct StagedRefreshError: LocalizedError, Sendable {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// The identifier is never interpreted as a path. Data survives process suspension;
/// no signing keys, account tokens or Core Data objects are stored here.
struct StagedRefreshBatchStore: Sendable {
    let directory: URL

    func removeExpiredBatches(now: Date = Date()) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            guard file.pathExtension == "json", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil else { continue }
            let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            // Retry checkpoints update mtime; they must not renew batch lifetime.
            // Damaged files cannot supply createdAt, so preserve their original
            // mtime and use that as a conservative cleanup fallback.
            let batch = try? JSONDecoder().decode(StagedRefreshBatch.self, from: Data(contentsOf: file))
            let created = batch?.createdAt ?? modified
            if now.timeIntervalSince(created) >= 86_400 { try FileManager.default.removeItem(at: file) }
        }
    }

    func url(for identifier: String) throws -> URL {
        guard let uuid = UUID(uuidString: identifier), uuid.uuidString.lowercased() == identifier.lowercased() else {
            throw StagedRefreshError("A valid preparation batch identifier is required.")
        }
        return directory.appendingPathComponent(uuid.uuidString).appendingPathExtension("json")
    }

    func save(_ batch: StagedRefreshBatch) throws {
        let destination = try url(for: batch.identifier)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        try JSONEncoder().encode(batch).write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(batch).write(to: destination, options: .atomic)
        #endif
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    func load(_ identifier: String) throws -> StagedRefreshBatch {
        let batch = try JSONDecoder().decode(StagedRefreshBatch.self, from: Data(contentsOf: url(for: identifier)))
        guard batch.identifier.lowercased() == identifier.lowercased(),
              Set(batch.entries.map { $0.identity.bundleIdentifier }).count == batch.entries.count else {
            throw StagedRefreshError("The saved batch is inconsistent. Prepare a new batch.")
        }
        return batch
    }
}
