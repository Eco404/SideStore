import Foundation

func validatedDeviceUDID(_ value: String?) -> String? {
    guard let udid = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !udid.isEmpty, udid != "XXXXX-XXXX-XXXXX-XXXX" else { return nil }
    return udid
}

func completeRequiredDeviceRegistration(
    skip: Bool,
    isCancelled: @Sendable () -> Bool,
    register: @Sendable () async throws -> Void,
    shouldRetry: @Sendable (Error) async -> Bool
) async throws {
    if isCancelled() || Task.isCancelled { throw CancellationError() }
    guard !skip else { return }

    while true {
        if isCancelled() || Task.isCancelled { throw CancellationError() }
        do {
            try await register()
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            return
        } catch {
            if error is CancellationError || isCancelled() || Task.isCancelled {
                throw CancellationError()
            }
            guard await shouldRetry(error) else { throw CancellationError() }
        }
    }
}
