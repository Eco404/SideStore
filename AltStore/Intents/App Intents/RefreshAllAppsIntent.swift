//
//  RefreshAllAppsIntent.swift
//  AltStore
//
//  Created by Riley Testut on 8/18/23.
//  Copyright © 2023 Riley Testut. All rights reserved.
//

import AppIntents

// Shouldn't conform types we don't own to protocols we don't own, so make custom
// NSError subclass that conforms to CustomLocalizedStringResourceConvertible instead.
//
// Would prefer to just conform ALTLocalizedError to CustomLocalizedStringResourceConvertible,
// but that can't be done without raising minimum version for ALTLocalizedError to iOS 16 :/
@available(iOS 16, tvOS 16, *)
class IntentError: NSError, CustomLocalizedStringResourceConvertible, @unchecked Sendable
{
    var localizedStringResource: LocalizedStringResource {
        return "\(self.localizedDescription)"
    }
    
    init(_ error: some Error)
    {
        let serializedError = (error as NSError).sanitizedForSerialization()
        super.init(domain: serializedError.domain, code: serializedError.code, userInfo: serializedError.userInfo)
    }
    
    required init?(coder: NSCoder)
    {
        super.init(coder: coder)
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct InstallIPAIntent: AppIntent, ProgressReportingIntent
{
    static var title: LocalizedStringResource = "Install IPA"
    static var description = IntentDescription("Installs an IPA file with SideStore.")
    static var openAppWhenRun = false

    @Parameter(title: "IPA File")
    var ipaFile: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Install \(\.$ipaFile)")
    }

    init()
    {
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }

    func perform() async throws -> some IntentResult
    {
        do
        {
            try await DatabaseManager.shared.start()

            let temporaryDirectory = FileManager.default.uniqueTemporaryURL()
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

            let ipaURL = temporaryDirectory.appendingPathComponent("App.ipa")
            try self.ipaFile.data.write(to: ipaURL)

            let intentProgress = self.progress
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<InstalledApp, Error>) in
                let group = AppManager.shared.install(.url(ipaURL)) { result in
                    continuation.resume(with: result)
                }
                intentProgress.addChild(group.progress, withPendingUnitCount: 1)
            }

            return .result()
        }
        catch
        {
            let intentError = IntentError(error)
            throw intentError
        }
    }
}


@available(iOS 17.0, tvOS 17.0, *)
extension RefreshAllAppsIntent
{
    private actor OperationActor
    {
        private(set) var operation: BackgroundRefreshAppsOperation?
        private var needsFinishedNotification = false
        
        func set(_ operation: BackgroundRefreshAppsOperation?)
        {
            self.operation = operation
            if self.needsFinishedNotification {
                operation?.presentsFinishedNotification = true
            }
        }

        func requestFinishedNotification()
        {
            self.needsFinishedNotification = true
            self.operation?.presentsFinishedNotification = true
        }
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct RefreshAllAppsIntent: AppIntent, CustomIntentMigratedAppIntent, PredictableIntent, ProgressReportingIntent, ForegroundContinuableIntent
{
    static let intentClassName = "RefreshAllIntent"
    
    static var title: LocalizedStringResource = "Refresh All Apps"
    static var description = IntentDescription("Refreshes your sideloaded apps to prevent them from expiring. Returns success or failure details so your shortcut can continue and restore network settings.")
    
    static var parameterSummary: some ParameterSummary {
        Summary("Refresh All Apps")
    }
    
    static var predictionConfiguration: some IntentPredictionConfiguration {
        IntentPrediction {
            DisplayRepresentation(
                title: "Refresh All Apps",
                subtitle: ""
            )
        }
    }
    
    let presentsNotifications: Bool
    
    private let operationActor = OperationActor()
    
    init(presentsNotifications: Bool)
    {
        self.presentsNotifications = presentsNotifications
        
        self.progress.completedUnitCount = 0
        self.progress.totalUnitCount = 1
    }
    
    init()
    {
        self.init(presentsNotifications: false)
    }
    
    func perform() async -> some IntentResult & ReturnsValue<RefreshShortcutResult> & ProvidesDialog
    {
        let report = await RefreshShortcutOutcome.run(operation: {
            await self.refreshAllApps()
        }, requestForeground: {
            await self.operationActor.requestFinishedNotification()
            try await self.requestToContinueInForeground()
        }, foregroundFailure: { error in
            debugLog("[RefreshAllAppsIntent] Could not continue in foreground: \(error.localizedDescription)")
        })

        return .result(value: RefreshShortcutResult(report: report), dialog: "\(report.message)")
    }
}

@available(iOS 17.0, tvOS 17.0, *)
private extension RefreshAllAppsIntent
{
    func refreshAllApps() async -> RefreshShortcutReport
    {
        do {
            try await DatabaseManager.shared.start()

            let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
            let installedApps = await context.perform { InstalledApp.fetchAppsForRefreshingAll(in: context) }
            let names = await context.perform {
                Dictionary(uniqueKeysWithValues: installedApps.map { ($0.bundleIdentifier, $0.name) })
            }

            guard !installedApps.isEmpty else {
                return RefreshShortcutReport(status: "no_apps", message: "There are no apps to refresh.", batchIdentifier: "", items: [])
            }

            return await RefreshShortcutOutcome.awaitCompletion(names: names) { completion in
                let operation = try AppManager.shared.backgroundRefresh(installedApps, presentsNotifications: self.presentsNotifications, completionHandler: completion)
                operation.ignoresServerNotFoundError = false
                self.progress.addChild(operation.progress, withPendingUnitCount: 1)
                Task {
                    await self.operationActor.set(operation)
                }
            }
        } catch {
            return RefreshShortcutOutcome.failure(error)
        }
    }
}
