import Foundation

func require(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}
func rejects(_ description: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected rejection: \(description)") } catch {}
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let store = StagedRefreshBatchStore(directory: directory)
func entry(_ id: String, useMainProfile: Bool = false) -> StagedRefreshEntry {
    StagedRefreshEntry(identity: StagedRefreshIdentity(objectURI: "test://\(id)", bundleIdentifier: id,
        resignedBundleIdentifier: id + ".TEAM", version: "1", buildVersion: "1", installedDate: Date(timeIntervalSince1970: 1),
        fingerprint: "fingerprint", certificateSerial: "cert", extensionIdentifiers: [id + ".TEAM.extension"], useMainProfile: useMainProfile),
        name: id, profiles: [id + ".TEAM": Data([1, 2, 3]), id + ".TEAM.extension": Data([4, 5, 6])])
}
let now = Date()
require(entry("test", useMainProfile: true).identity.profileTargets == ["test.TEAM"], "Single-profile mode prepares/installs only parent profile")
require(entry("test").identity.profileTargets == ["test.TEAM", "test.TEAM.extension"], "Separate-profile mode includes extensions")
var batch = StagedRefreshBatch(identifier: UUID().uuidString, createdAt: now, teamIdentifier: "team",
    accountIdentifier: "account", deviceIdentifier: "device", entries: [entry("one"), entry("two")], preparationFailures: [])
rejects("empty id") { _ = try store.load("") }
rejects("path traversal") { _ = try store.url(for: "../../escape") }
try store.save(batch)
var restored = try store.load(batch.identifier.lowercased())
require(restored.entries.count == 2 && restored.entries[0].profiles == batch.entries[0].profiles, "Persistence round trip")
require(restored.entries[0].identity == batch.entries[0].identity, "Snapshot round trip")
try restored.validate(team: "team", account: "account", device: "device", now: now)
rejects("team change") { try restored.validate(team: "different", account: "account", device: "device", now: now) }
rejects("account change") { try restored.validate(team: "team", account: "different", device: "device", now: now) }
rejects("device change") { try restored.validate(team: "team", account: "account", device: "different", now: now) }
rejects("stale batch") { try restored.validate(team: "team", account: "account", device: "device", now: now.addingTimeInterval(86400)) }
rejects("future batch") { try restored.validate(team: "team", account: "account", device: "device", now: now.addingTimeInterval(-61)) }
try restored.markApplied(bundleIdentifier: "one")
try store.save(restored)
restored = try store.load(batch.identifier)
require(restored.entries.filter { !$0.applied }.map { $0.identity.bundleIdentifier } == ["two"], "Retry excludes succeeded app")
require(restored.entries[0].profiles.isEmpty, "Applied payload is removed immediately")
require(restored.entries[1].profiles == batch.entries[1].profiles, "Failed/pending payload is retained for retry")
try restored.markApplied(bundleIdentifier: "one")
require(restored.entries.filter(\.applied).count == 1, "Repeated success marker is idempotent")
try restored.markApplied(bundleIdentifier: "two")
try store.save(restored)
let completed = try store.load(batch.identifier)
require(completed.entries.allSatisfy(\.applied), "Completed batch replay requires no writes")
require(completed.entries.allSatisfy { $0.profiles.isEmpty }, "Consumed batch contains no profile payloads")
rejects("unknown app") { try restored.markApplied(bundleIdentifier: "missing") }
batch.entries.append(batch.entries[0])
try store.save(batch)
rejects("duplicate entries") { _ = try store.load(batch.identifier) }
try Data("broken JSON".utf8).write(to: store.url(for: batch.identifier))
rejects("corrupt persistence") { _ = try store.load(batch.identifier) }
// Successful checkpoints must not extend the 24-hour deadline, and unused
// preparations must expire even though their files were recently written.
let abandoned = StagedRefreshBatch(identifier: UUID().uuidString, createdAt: now.addingTimeInterval(-86401),
    teamIdentifier: "team", accountIdentifier: "account", deviceIdentifier: "device", entries: [entry("abandoned")], preparationFailures: [])
try store.save(abandoned)
var retried = StagedRefreshBatch(identifier: UUID().uuidString, createdAt: now.addingTimeInterval(-86401),
    teamIdentifier: "team", accountIdentifier: "account", deviceIdentifier: "device", entries: [entry("done"), entry("pending")], preparationFailures: [])
try retried.markApplied(bundleIdentifier: "done")
try store.save(retried)
let fresh = StagedRefreshBatch(identifier: UUID().uuidString, createdAt: now,
    teamIdentifier: "team", accountIdentifier: "account", deviceIdentifier: "device", entries: [entry("fresh")], preparationFailures: [])
try store.save(fresh)
let oldCorruptID = UUID().uuidString
let oldCorrupt = try store.url(for: oldCorruptID)
try Data("invalid JSON".utf8).write(to: oldCorrupt)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-86401)], ofItemAtPath: oldCorrupt.path)
let foreignFile = directory.appendingPathComponent("unowned.json")
try Data("keep me".utf8).write(to: foreignFile)
try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-86401)], ofItemAtPath: foreignFile.path)
try store.removeExpiredBatches(now: now)
rejects("abandoned preparation expires by creation time") { _ = try store.load(abandoned.identifier) }
rejects("retry checkpoint cannot extend expiry") { _ = try store.load(retried.identifier) }
require(!FileManager.default.fileExists(atPath: oldCorrupt.path), "Old corrupt file is pruned using original mtime")
require(FileManager.default.fileExists(atPath: foreignFile.path), "Unowned files are preserved")
let recentCorruptPath = try store.url(for: batch.identifier).path
require(FileManager.default.fileExists(atPath: recentCorruptPath), "Recent corrupt file is preserved until deadline")
let retained = try store.load(fresh.identifier)
require(!retained.entries[0].profiles.isEmpty, "Unexpired unused batch remains usable")
let failure = RefreshShortcutReport(status: "failure", message: "failed", batchIdentifier: "", items: [])
require(!failure.succeeded, "Failure is a returned report")
let gate = RefreshExecutionGate()
require(gate.beginOrdinary(), "Ordinary operation can reserve")
require(gate.beginOrdinary(), "Ordinary pipelines retain concurrency")
require(!gate.beginStaged(), "Staged cannot overlap ordinary pipeline")
gate.endOrdinary()
require(!gate.beginStaged(), "All ordinary pipelines must finish")
gate.endOrdinary()
require(gate.beginStaged(), "Staged can reserve idle pipeline")
require(!gate.beginOrdinary() && !gate.beginStaged(), "Staged reservation is exclusive")
gate.endStaged()
require(gate.beginOrdinary(), "Reservation releases after completion/failure")
gate.endOrdinary()
print("Staged refresh persistence, binding, expiry, partial retry and replay checks passed")
