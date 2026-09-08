import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

enum RegistrationFailure: Error, Equatable {
    case disconnected
}

func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw TestFailure(description: message) }
}

actor RegistrationProbe {
    private(set) var attempts = 0
    private(set) var reportedErrors = 0
    private var failuresRemaining: Int

    init(failuresRemaining: Int = 0) {
        self.failuresRemaining = failuresRemaining
    }

    func register() throws {
        attempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw RegistrationFailure.disconnected
        }
    }

    func report(_ error: Error, retry: Bool) -> Bool {
        if error as? RegistrationFailure == .disconnected {
            reportedErrors += 1
        }
        return retry
    }
}

func testUDIDValidation() throws {
    for value: String? in [nil, "", " \n", "XXXXX-XXXX-XXXXX-XXXX", " XXXXX-XXXX-XXXXX-XXXX "] {
        try expect(validatedDeviceUDID(value) == nil, "An unavailable or placeholder UDID was accepted")
    }
    let udid = "00008120-0011223344556677"
    try expect(validatedDeviceUDID(udid) == udid, "A device UDID was rejected")
    try expect(validatedDeviceUDID(" \(udid)\n") == udid, "UDID whitespace was not normalized")
}

func testExplicitSkipDoesNotConnect() async throws {
    let probe = RegistrationProbe(failuresRemaining: 1)
    try await completeRequiredDeviceRegistration(
        skip: true, isCancelled: { false },
        register: { try await probe.register() },
        shouldRetry: { await probe.report($0, retry: false) }
    )
    try expect(await probe.attempts == 0, "Explicit skip attempted device communication")
    try expect(await probe.reportedErrors == 0, "Explicit skip prompted for a device error")
}

func testEveryRequiredInvocationRegisters() async throws {
    let probe = RegistrationProbe()
    for _ in 0..<2 {
        try await completeRequiredDeviceRegistration(
            skip: false, isCancelled: { false },
            register: { try await probe.register() },
            shouldRetry: { await probe.report($0, retry: false) }
        )
    }
    try expect(await probe.attempts == 2, "A subsequent required registration was skipped")
    try expect(await probe.reportedErrors == 0, "Successful registration prompted for an error")
}

func testRetryPreservesTheConnectionError() async throws {
    let probe = RegistrationProbe(failuresRemaining: 1)
    try await completeRequiredDeviceRegistration(
        skip: false, isCancelled: { false },
        register: { try await probe.register() },
        shouldRetry: { await probe.report($0, retry: true) }
    )
    try expect(await probe.attempts == 2, "Retry did not run device registration again")
    try expect(await probe.reportedErrors == 1, "The original connection error did not reach the handler")
}

func testCancelCannotReportSuccessAndNextInvocationRegisters() async throws {
    let probe = RegistrationProbe(failuresRemaining: 1)
    do {
        try await completeRequiredDeviceRegistration(
            skip: false, isCancelled: { false },
            register: { try await probe.register() },
            shouldRetry: { await probe.report($0, retry: false) }
        )
        throw TestFailure(description: "Cancelling device registration was reported as success")
    } catch is CancellationError {}

    try await completeRequiredDeviceRegistration(
        skip: false, isCancelled: { false },
        register: { try await probe.register() },
        shouldRetry: { await probe.report($0, retry: false) }
    )
    try expect(await probe.attempts == 2, "Registration was bypassed after an earlier cancellation")
    try expect(await probe.reportedErrors == 1, "Cancellation did not retain the connection error for the handler")
}

func testCancellationDoesNotRetry() async throws {
    let probe = RegistrationProbe()
    do {
        try await completeRequiredDeviceRegistration(
            skip: false, isCancelled: { false },
            register: { throw CancellationError() },
            shouldRetry: { await probe.report($0, retry: true) }
        )
        throw TestFailure(description: "Task cancellation was reported as registration success")
    } catch is CancellationError {}
    try expect(await probe.reportedErrors == 0, "Task cancellation entered the retry handler")

    do {
        try await completeRequiredDeviceRegistration(
            skip: false, isCancelled: { true },
            register: { try await probe.register() },
            shouldRetry: { await probe.report($0, retry: true) }
        )
        throw TestFailure(description: "An already cancelled operation reported success")
    } catch is CancellationError {}
    try expect(await probe.attempts == 0, "An already cancelled operation contacted the device")
}

@main
struct DeviceRegistrationTests {
    static func main() async throws {
        try testUDIDValidation()
        try await testExplicitSkipDoesNotConnect()
        try await testEveryRequiredInvocationRegisters()
        try await testRetryPreservesTheConnectionError()
        try await testCancelCannotReportSuccessAndNextInvocationRegisters()
        try await testCancellationDoesNotRetry()
        print("Passed 6 device registration flow tests")
    }
}
