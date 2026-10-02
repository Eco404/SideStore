import AppIntents

/// Transient output exposes fields without asking Shortcuts to resolve a saved entity.
@available(iOS 17.0, tvOS 17.0, *)
struct RefreshShortcutResult: TransientAppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Refresh Result"

    @Property(title: "Success") var success: Bool
    @Property(title: "Status") var status: String
    @Property(title: "Message") var message: String
    @Property(title: "Batch Identifier") var batchIdentifier: String
    @Property(title: "Successful Apps") var successfulApps: Int
    @Property(title: "Failed Apps") var failedApps: Int
    @Property(title: "App Results") var appResults: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(message)", subtitle: "\(status)")
    }

    init() {
        success = false
        status = "failure"
        message = "No refresh result is available."
        batchIdentifier = ""
        successfulApps = 0
        failedApps = 0
        appResults = ""
    }

    init(report: RefreshShortcutReport) {
        self.init()
        success = report.succeeded
        status = report.status
        message = report.message
        batchIdentifier = report.batchIdentifier
        successfulApps = report.succeededCount
        failedApps = report.failedCount
        appResults = report.details
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct PrepareRefreshProfilesIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Prepare All App Refresh Profiles"
    static var description = IntentDescription("Downloads and saves profiles for active apps without changing network settings. Pass the result's Batch Identifier to Refresh Apps with Prepared Profiles. Failures are returned in the result so your shortcut can continue.")
    static var openAppWhenRun = false

    func perform() async -> some IntentResult & ReturnsValue<RefreshShortcutResult> & ProvidesDialog {
        let report = await RefreshShortcutOutcome.run(operation: {
            await StagedRefreshService.shared.prepare()
        }, requestForeground: {
            try await self.requestToContinueInForeground()
        }, foregroundFailure: { error in
            debugLog("[PrepareRefreshProfilesIntent] Could not continue in foreground: \(error.localizedDescription)")
        })
        return .result(value: RefreshShortcutResult(report: report), dialog: "\(report.message)")
    }
}

@available(iOS 17.0, tvOS 17.0, *)
struct ApplyRefreshProfilesIntent: AppIntent, ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "Refresh Apps with Prepared Profiles"
    static var description = IntentDescription("Installs a saved batch through the device connection without accessing Apple or changing network settings. Returns success, partial success, or failure so your shortcut can restore its network settings.")
    static var openAppWhenRun = false

    // A text parameter with an empty default lets invalid/missing batches return a result
    // instead of failing entity resolution before perform() can run.
    @Parameter(title: "Batch Identifier", default: "") var batchIdentifier: String

    static var parameterSummary: some ParameterSummary {
        Summary("Refresh apps using batch \(\.$batchIdentifier)")
    }

    func perform() async -> some IntentResult & ReturnsValue<RefreshShortcutResult> & ProvidesDialog {
        let report = await RefreshShortcutOutcome.run(operation: {
            await StagedRefreshService.shared.apply(batchIdentifier: self.batchIdentifier)
        }, requestForeground: {
            try await self.requestToContinueInForeground()
        }, foregroundFailure: { error in
            debugLog("[ApplyRefreshProfilesIntent] Could not continue in foreground: \(error.localizedDescription)")
        })
        return .result(value: RefreshShortcutResult(report: report), dialog: "\(report.message)")
    }
}
