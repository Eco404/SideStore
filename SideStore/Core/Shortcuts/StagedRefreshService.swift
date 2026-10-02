import Foundation
import CoreData
import SideSign
import Minimuxer

/// Deliberately bypasses PipelineRunner and CellularRefreshManager: the caller
/// owns network state. Errors are values so its next cleanup action can execute.
actor StagedRefreshService {
    static let shared = StagedRefreshService()
    private var busy = false

    private var store: StagedRefreshBatchStore {
        get throws {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return StagedRefreshBatchStore(directory: support.appendingPathComponent("PreparedRefreshBatches", isDirectory: true))
        }
    }

    /// Best-effort startup maintenance. No timer or detached work is required;
    /// every preparation/application also cleans before accessing saved batches.
    func cleanupExpiredBatches() {
        guard !busy, RefreshExecutionGate.shared.beginStaged() else { return }
        defer { RefreshExecutionGate.shared.endStaged() }
        do { try store.removeExpiredBatches() }
        catch { debugLog("[StagedRefresh] Could not clean expired batches: \(error.localizedDescription)") }
    }

    func prepare() async -> RefreshShortcutReport {
        guard !busy, !AppManager.shared.isActivelyManagingAnyApp else { return failure("Another app operation is running. Try again after it finishes.") }
        guard RefreshExecutionGate.shared.beginStaged() else { return failure("Another app operation is running. Try again after it finishes.") }
        defer { RefreshExecutionGate.shared.endStaged() }
        busy = true
        defer { busy = false }
        var items: [RefreshShortcutItem] = []
        do {
            try store.removeExpiredBatches()
            try await DatabaseManager.shared.start()
            try Task.checkCancellation()
            let binding = try await currentBinding()
            let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            let apps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }
            guard !apps.isEmpty else { return report(items: [], batch: "", message: "No applications need refreshing.") }
            var batch = StagedRefreshBatch(identifier: UUID().uuidString, createdAt: Date(), teamIdentifier: binding.team,
                accountIdentifier: binding.account, deviceIdentifier: binding.device, entries: [], preparationFailures: [])
            let shared = SharedPipelineContext()
            for app in apps {
                let (bundleID, name) = await context.perform { (app.bundleIdentifier, app.name) }
                do {
                    try Task.checkCancellation()
                    guard !AppManager.shared.isActivelyManagingAnyApp else { throw StagedRefreshError("Another app operation started. Try again after it finishes.") }
                    let identity = try await context.perform { try Self.identity(app) }
                    let operationContext = await context.perform {
                        let value = InstallAppOperationContext(pipelineSteps: [], bundleIdentifier: app.bundleIdentifier,
                            dbBackgroundContext: context, sharedContext: shared, handler: PipelineHandler(),
                            additionalEntitlements: OperationEntitlements.defaultAdditionalEntitlements,
                            activeSigningCertificate: CertificateManager.shared.activeCertificate?.certificate)
                        value.installedApp = app
                        value.appBundleFingerprint = app.appBundleFingerprint
                        value.useMainProfile = app.useMainProfile
                        value.customBundleIdentifier = app.customBundleIdentifier
                        value.targetAppBundle = ALTApplication(fileURL: app.fileURL)
                        return value
                    }
                    guard operationContext.targetAppBundle != nil else {
                        throw StagedRefreshError("Cached application bundle is missing. Refresh this application in SideStore first.")
                    }
                    try await UpdateAppCertificateOperation(context: operationContext).execute()
                    try await VerifyCertificateOperation(context: operationContext, willResign: false).execute()
                    try Task.checkCancellation()
                    let fetched = try await FetchProvisioningProfilesOperation(context: operationContext).execute()
                    // Resolve by signed identifiers, never arbitrary dictionary order.
                    let targets = identity.profileTargets
                    var data: [String: Data] = [:]
                    for target in targets {
                        guard let profile = fetched.values.first(where: { $0.bundleIdentifier == target })
                            ?? fetched.values.first(where: { Self.profile($0, matches: target) }) else {
                            throw StagedRefreshError("No matching profile for \(target). A full re-sign may be required.")
                        }
                        try Self.validate(profile, target: target, identity: identity, batch: batch)
                        data[target] = profile.data
                    }
                    let currentIdentity = try await context.perform {
                        context.refresh(app, mergeChanges: false)
                        return try Self.identity(app)
                    }
                    guard currentIdentity == identity else { throw StagedRefreshError("Application changed while preparing. Prepare again.") }
                    batch.entries.append(StagedRefreshEntry(identity: identity, name: name, profiles: data))
                    items.append(RefreshShortcutItem(bundleIdentifier: bundleID, name: name, success: true, message: "Prepared; not yet installed."))
                } catch {
                    items.append(RefreshShortcutItem(bundleIdentifier: bundleID, name: name, success: false, message: error.localizedDescription))
                }
            }
            guard !batch.entries.isEmpty else { return report(items: items, batch: "", message: "No profiles were prepared.") }
            let persisted = StagedRefreshBatch(identifier: batch.identifier, createdAt: batch.createdAt,
                teamIdentifier: batch.teamIdentifier, accountIdentifier: batch.accountIdentifier, deviceIdentifier: batch.deviceIdentifier,
                entries: batch.entries, preparationFailures: items.filter { !$0.success })
            try store.save(persisted)
            return report(items: items, batch: batch.identifier, message: "Preparation finished. Pass this batch to Refresh Apps with Prepared Profiles.")
        } catch {
            return failure(error.localizedDescription)
        }
    }

    func apply(batchIdentifier: String) async -> RefreshShortcutReport {
        guard !busy, !AppManager.shared.isActivelyManagingAnyApp else { return failure("Another app operation is running. Try again after it finishes.", batch: batchIdentifier) }
        guard RefreshExecutionGate.shared.beginStaged() else { return failure("Another app operation is running. Try again after it finishes.", batch: batchIdentifier) }
        defer { RefreshExecutionGate.shared.endStaged() }
        busy = true
        defer { busy = false }
        var items: [RefreshShortcutItem] = []
        var loadedEntries: [StagedRefreshEntry] = []
        do {
            let store = try self.store
            try store.removeExpiredBatches()
            try await DatabaseManager.shared.start()
            var batch = try store.load(batchIdentifier)
            loadedEntries = batch.entries
            items = batch.preparationFailures
            let binding = try await currentBinding()
            try batch.validate(team: binding.team, account: binding.account, device: binding.device)
            if batch.entries.contains(where: { !$0.applied }) {
                try Task.checkCancellation()
                // No Wi-Fi/cellular setting check; establish the local device path only.
                try await ensureDeviceConnection()
                let liveDevice = try await fetchUDID(forceLive: true)
                guard liveDevice == batch.deviceIdentifier else { throw StagedRefreshError("Connected device differs from the prepared batch.") }
            }
            let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            for entry in batch.entries {
                let id = entry.identity.bundleIdentifier
                if entry.applied {
                    items.append(RefreshShortcutItem(bundleIdentifier: id, name: entry.name, success: true, message: "Already applied; skipped."))
                    continue
                }
                do {
                    try Task.checkCancellation()
                    guard !AppManager.shared.isActivelyManagingAnyApp else { throw StagedRefreshError("Another app operation started. Retry this batch after it finishes.") }
                    let currentBinding = try await currentBinding()
                    try batch.validate(team: currentBinding.team, account: currentBinding.account, device: currentBinding.device)
                    let app = try await context.perform {
                        guard let app = InstalledApp.first(satisfying: NSPredicate(format: "bundleIdentifier == %@", id), in: context),
                              try Self.identity(app) == entry.identity else {
                            throw StagedRefreshError("Application changed or was removed. Prepare a new batch.")
                        }
                        return app
                    }
                    let targets = entry.identity.profileTargets
                    guard Set(entry.profiles.keys) == Set(targets) else { throw StagedRefreshError("Batch is missing application or extension profiles.") }
                    var profiles: [String: ALTProvisioningProfile] = [:]
                    for target in targets {
                        let profile = try ALTProvisioningProfile(data: entry.profiles[target]!)
                        try Self.validate(profile, target: target, identity: entry.identity, batch: batch)
                        profiles[target] = profile
                    }
                    let preparedProfiles = profiles
                    try await context.perform {
                        context.refresh(app, mergeChanges: false)
                        guard let main = preparedProfiles[app.resignedBundleIdentifier],
                              main.expirationDate >= app.expirationDate, main.creationDate >= app.refreshedDate else {
                            throw StagedRefreshError("This application has already received a newer profile. Prepare a new batch.")
                        }
                        for ext in app.appExtensions where !entry.identity.useMainProfile {
                            context.refresh(ext, mergeChanges: false)
                            guard let profile = preparedProfiles[ext.resignedBundleIdentifier],
                                  profile.expirationDate >= ext.expirationDate, profile.creationDate >= ext.refreshedDate else {
                                throw StagedRefreshError("An extension has already received a newer profile. Prepare a new batch.")
                            }
                        }
                    }
                    // Validate every profile before the first remote write. The remote
                    // service is not transactional: partial installs are safe to retry.
                    for target in targets {
                        try Task.checkCancellation()
                        try await installProvisioningProfiles(profiles[target]!.data)
                    }
                    try Task.checkCancellation()
                    let installedProfiles = profiles
                    try await context.perform {
                        context.refresh(app, mergeChanges: false)
                        guard try Self.identity(app) == entry.identity else { throw StagedRefreshError("Application changed during installation. Prepare again.") }
                        app.update(provisioningProfile: installedProfiles[entry.identity.resignedBundleIdentifier]!)
                        for ext in app.appExtensions where !entry.identity.useMainProfile {
                            if let profile = installedProfiles[ext.resignedBundleIdentifier] { ext.update(provisioningProfile: profile) }
                        }
                        try context.save()
                    }
                    try batch.markApplied(bundleIdentifier: id)
                    try store.save(batch)
                    items.append(RefreshShortcutItem(bundleIdentifier: id, name: entry.name, success: true, message: "Refreshed."))
                    await WidgetDataManager.publishCurrentInstalledApps(in: context)
                } catch {
                    await context.perform { context.rollback() }
                    items.append(RefreshShortcutItem(bundleIdentifier: id, name: entry.name, success: false, message: error.localizedDescription))
                }
            }
            return report(items: items, batch: batch.identifier, message: "Refresh finished. Restore network settings before handling this result.")
        } catch {
            let reported = Set(items.map(\.bundleIdentifier))
            items.append(contentsOf: loadedEntries.filter { !reported.contains($0.identity.bundleIdentifier) }.map {
                RefreshShortcutItem(bundleIdentifier: $0.identity.bundleIdentifier, name: $0.name,
                    success: $0.applied, message: $0.applied ? "Already applied; skipped." : "Not applied: \(error.localizedDescription)")
            })
            return RefreshShortcutReport(status: "failure", message: error.localizedDescription, batchIdentifier: batchIdentifier, items: items)
        }
    }

    private func currentBinding() async throws -> (team: String, account: String, device: String) {
        guard AuthManager.shared.isAuthenticated, let account = AuthManager.shared.adsid,
              let device = Keychain.shared.deviceUDID, !device.isEmpty else {
            throw StagedRefreshError("Sign in and complete device registration in SideStore before running these actions.")
        }
        // Read the active database team directly; no authentication/network operation.
        let team = try await DatabaseManager.shared.persistentContainer.performBackgroundTask { context in
            guard let team = DatabaseManager.shared.activeTeam(in: context) else { throw OperationError.notAuthenticated }
            return team.identifier
        }
        return (team, account, device)
    }

    private func ensureDeviceConnection() async throws {
        var lastError: Error = StagedRefreshError("Device connection is not ready. Check the local VPN and unlock the device.")
        var didStart = false
        // Network configuration has just changed in the caller. Refresh cached
        // endpoint discovery and allow a short, cancellable settling interval.
        for attempt in 0..<10 {
            try Task.checkCancellation()
            await minimuxer.network.refreshEndpoint()
            switch await minimuxer.core.isReady(withNetworkCheck: false) {
            case .success(true): return
            case .success(false): break
            case .failure(let error):
                lastError = error
                switch error {
                case .pairingNotLoaded, .notStarted:
                    if attempt >= 2, !didStart {
                        guard let pairing = PairingFileManager.shared.fetchPairingFile() else {
                            throw StagedRefreshError("No pairing file is saved. Set up pairing in SideStore first.")
                        }
                        didStart = true
                        try await minimuxerStart(pairing, preferred: PairingFileManager.shared.preferredProtocol)
                    }
                default: break
                }
            }
            if attempt < 9 { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        throw lastError
    }

    private static func identity(_ app: InstalledApp) throws -> StagedRefreshIdentity {
        let certificateSerial = app.certificateSerialNumber
            ?? CertificateManager.shared.getSigningCertificate(for: app)?.serialNumber
        guard app.isActive, let serial = certificateSerial, !serial.isEmpty else {
            throw StagedRefreshError("Application has no saved signing certificate or is inactive. Refresh it in SideStore first.")
        }
        return StagedRefreshIdentity(objectURI: app.objectID.uriRepresentation().absoluteString,
            bundleIdentifier: app.bundleIdentifier, resignedBundleIdentifier: app.resignedBundleIdentifier,
            version: app.version, buildVersion: app.buildVersion, installedDate: app.installedDate,
            fingerprint: app.appBundleFingerprint, certificateSerial: serial,
            extensionIdentifiers: app.appExtensions.map(\.resignedBundleIdentifier).sorted(), useMainProfile: app.useMainProfile)
    }

    private static func profile(_ profile: ALTProvisioningProfile, matches target: String) -> Bool {
        if profile.bundleIdentifier == target { return true }
        guard profile.bundleIdentifier.hasSuffix(".*") else { return profile.bundleIdentifier == "*" }
        return target.hasPrefix(String(profile.bundleIdentifier.dropLast()))
    }

    private static func validate(_ profile: ALTProvisioningProfile, target: String,
                                 identity: StagedRefreshIdentity, batch: StagedRefreshBatch) throws {
        guard profile.expirationDate > Date(), profile.teamIdentifier == batch.teamIdentifier,
              Self.profile(profile, matches: target), profile.deviceIDs.contains(batch.deviceIdentifier),
              profile.certificates.contains(where: { $0.serialNumber == identity.certificateSerial && $0.expiryDate > Date() }) else {
            throw StagedRefreshError("Profile for \(target) is expired or does not match this device, team or signing certificate. Prepare again or re-sign in SideStore.")
        }
    }

    private func failure(_ message: String, batch: String = "") -> RefreshShortcutReport {
        RefreshShortcutReport(status: "failure", message: message, batchIdentifier: batch, items: [])
    }

    private func report(items: [RefreshShortcutItem], batch: String, message: String) -> RefreshShortcutReport {
        let status = items.isEmpty ? "no_apps" : items.allSatisfy(\.success) ? "success" : items.contains(where: \.success) ? "partial" : "failure"
        return RefreshShortcutReport(status: status, message: message, batchIdentifier: batch, items: items)
    }
}
