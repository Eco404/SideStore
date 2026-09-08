import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

final class LockedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(line)
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return entries.joined(separator: "\n")
    }
}

final class RedirectDecision: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var request: URLRequest?

    func record(_ request: URLRequest?) {
        lock.lock()
        defer { lock.unlock() }
        calls += 1
        self.request = request
    }

    func snapshot() -> (Int, URLRequest?) {
        lock.lock()
        defer { lock.unlock() }
        return (calls, request)
    }
}

struct MockReply: Sendable {
    let status: Int
    let data: Data
    let error: URLError?

    init(status: Int = 200, data: Data = Data("ok".utf8), error: URLError? = nil) {
        self.status = status
        self.data = data
        self.error = error
    }
}

final class MockState: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [MockReply] = []
    private var requests: [URLRequest] = []

    func reset(_ replies: [MockReply]) {
        lock.lock()
        defer { lock.unlock() }
        self.replies = replies
        requests = []
    }

    func next(for request: URLRequest) -> MockReply {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        guard !replies.isEmpty else { return MockReply(error: URLError(.resourceUnavailable)) }
        return replies.removeFirst()
    }

    func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = MockState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.state.next(for: request)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                             httpVersion: "HTTP/1.1", headerFields: [:]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

struct Rig {
    let session: URLSession
    let log: LockedLog
    let transport: AppleAuthenticationTransport

    init(_ mode: AppleAuthenticationMode, replies: [MockReply]) {
        MockURLProtocol.state.reset(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
        log = LockedLog()
        let sink = log
        transport = AppleAuthenticationTransport(session: session, mode: mode) { sink.append($0) }
    }
}

let secrets = [
    "fixture@example.invalid", "private-password", "private-md", "private-token", "private-query",
    "private-dsid", "private-machine", "private-device", "private-api-header"
]

func expectRedacted(_ text: String) throws {
    for secret in secrets {
        try expect(!text.contains(secret), "Diagnostic leaked a fixture secret")
    }
}

func clientData() -> [String: any Sendable] {
    [
        "bootstrap": true, "icscrec": true, "pbe": false, "prkgen": true,
        "svct": "iCloud", "loc": "zh_CN", "X-Apple-Locale": "zh_CN",
        "X-Apple-I-MD": "private-md", "X-Apple-I-MD-M": "machine-id",
        "X-Mme-Device-Id": "device-id", "X-Apple-I-MD-LU": "local-user",
        "X-Apple-I-MD-RINFO": "17106176", "X-Apple-I-SRL-NO": "0",
        "X-Apple-I-Client-Time": "2026-09-08T00:00:00Z", "X-Apple-I-TimeZone": "CST"
    ]
}

func authenticationRequest(_ mode: AppleAuthenticationMode, stage: AppleAuthenticationStage) throws -> URLRequest {
    var request = URLRequest(url: URL(string: "https://gsa.apple.com/grandslam/GsService2?value=private-query")!)
    request.httpMethod = "POST"
    mode.headers(clientInfo: "original-client", userAgent: "original-agent").forEach {
        request.setValue($1, forHTTPHeaderField: $0)
    }
    let parameters: [String: any Sendable] = [
        "o": stage.rawValue, "u": secrets[0], "t": secrets[3],
        "cpd": mode.clientData(clientData())
    ]
    request.httpBody = try PropertyListSerialization.data(
        fromPropertyList: ["Header": ["Version": "1.0.1"], "Request": parameters], format: .xml, options: 0
    )
    return request
}

func serializedClientData(_ request: URLRequest) throws -> [String: Any] {
    guard let body = request.httpBody,
          let root = try PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any],
          let parameters = root["Request"] as? [String: Any],
          let data = parameters["cpd"] as? [String: Any] else {
        throw TestFailure(description: "Serialized request did not contain CPD")
    }
    return data
}

func lookupReply(_ url: String) throws -> MockReply {
    MockReply(data: try PropertyListSerialization.data(
        fromPropertyList: ["urls": ["gsService": url]], format: .xml, options: 0
    ))
}

func testStandardPolicy() async throws {
    let rig = Rig(.standard, replies: [MockReply()])
    defer { rig.session.invalidateAndCancel() }
    let request = try authenticationRequest(.standard, stage: .initialize)
    let serialized = try serializedClientData(request)
    try expect(Set(serialized.keys) == Set(clientData().keys), "Standard CPD dropped fields")
    for key in ["bootstrap", "icscrec", "prkgen"] {
        try expect(serialized[key] as? Bool == true, "Standard CPD lost a boolean flag")
        try expect(!(serialized[key] is String), "Standard CPD converted a flag to text")
    }
    try expect(serialized["pbe"] as? Bool == false, "Standard pbe flag changed")
    try expect(serialized["loc"] as? String == "zh_CN", "Standard locale changed")
    try expect(serialized["X-Apple-I-MD-LU"] as? String == "local-user", "Standard LU changed")
    let headers = AppleAuthenticationMode.standard.headers(clientInfo: "original-client", userAgent: "original-agent")
    try expect(headers == ["Content-Type": "text/x-xml-plist", "Accept": "*/*",
                           "X-MMe-Client-Info": "original-client", "User-Agent": "original-agent"],
               "Standard header policy changed")
    _ = try await rig.transport.send(request, stage: .initialize)
    let sent = MockURLProtocol.state.recordedRequests()
    try expect(sent.count == 1, "Standard request was not sent once")
    try expect(sent[0].value(forHTTPHeaderField: "X-MMe-Client-Info") == "original-client", "Standard client header changed in transit")
    try expect(sent[0].value(forHTTPHeaderField: "X-Xcode-Version") == nil, "Standard acquired compatibility headers")
    try expectRedacted(rig.log.text())
}

func testIloaderPolicyAndConnections() async throws {
    let rig = Rig(.iloader, replies: Array(repeating: MockReply(), count: 3))
    defer { rig.session.invalidateAndCancel() }
    let original = try authenticationRequest(.iloader, stage: .initialize)
    let serialized = try serializedClientData(original)
    let keys: Set<String> = ["bootstrap", "icscrec", "pbe", "prkgen", "svct", "loc",
                             "X-Apple-I-MD", "X-Apple-I-MD-M", "X-Mme-Device-Id"]
    try expect(Set(serialized.keys) == keys, "iLoader CPD contained extra or missing fields")
    for key in ["bootstrap", "icscrec", "prkgen"] {
        try expect(serialized[key] as? String == "true", "iLoader flag was not serialized as text")
    }
    try expect(serialized["pbe"] as? String == "false", "iLoader pbe flag changed")
    try expect(serialized["loc"] as? String == "en_US", "iLoader locale changed")
    try expect(serialized["X-Apple-I-MD"] as? String == "private-md", "iLoader lost provided anisette data")
    for stage in [AppleAuthenticationStage.initialize, .complete, .appTokens] {
        _ = try await rig.transport.send(original, stage: stage)
    }
    let sent = MockURLProtocol.state.recordedRequests()
    try expect(sent.count == 3, "Wrong number of iLoader requests")
    try expect(sent[0].value(forHTTPHeaderField: "Connection") != "close", "init received complete-only Connection header")
    try expect(sent[1].value(forHTTPHeaderField: "Connection") == "close", "complete did not close its connection")
    try expect(sent[2].value(forHTTPHeaderField: "Connection") != "close", "apptokens inherited Connection header")
    try expect(original.value(forHTTPHeaderField: "Connection") == nil, "Transport mutated the caller request")
    let expectedHeaders = [
        "Accept": "text/x-xml-plist", "X-Apple-App-Info": "com.apple.gs.xcode.auth",
        "X-Xcode-Version": "27.0 (27A5218g)", "User-Agent": "akd/1.0 CFNetwork/808.1.4",
        "X-MMe-Client-Info": "<Mac15,7> <macOS;27.0;26A5378j> <com.apple.AuthKit/1 (com.apple.dt.Xcode/25183.54.10)>"
    ]
    for (key, value) in expectedHeaders {
        try expect(sent[0].value(forHTTPHeaderField: key) == value, "iLoader client header mismatch: \(key)")
    }
    try expectRedacted(rig.log.text())
}

func testLookupAndCache() async throws {
    let standard = Rig(.standard, replies: [])
    defer { standard.session.invalidateAndCancel() }
    let standardURL = try await standard.transport.authenticationURL()
    try expect(standardURL.absoluteString == "https://gsa.apple.com/grandslam/GsService2", "Standard endpoint changed")
    try expect(MockURLProtocol.state.recordedRequests().isEmpty, "Standard performed a lookup")

    let resolved = "https://gsa-alt.apple.com/grandslam/GsService2?value=private-query"
    let rig = Rig(.iloader, replies: [try lookupReply(resolved)])
    defer { rig.session.invalidateAndCancel() }
    let first = try await rig.transport.authenticationURL()
    let second = try await rig.transport.authenticationURL()
    try expect(first.absoluteString == resolved && second == first, "Lookup endpoint or cached endpoint changed")
    let sent = MockURLProtocol.state.recordedRequests()
    try expect(sent.count == 1, "Successful lookup was not cached")
    try expect(sent[0].httpMethod == "GET" && sent[0].url?.path == "/grandslam/GsService2/lookup", "Wrong lookup request")
    try expect(sent[0].value(forHTTPHeaderField: "X-Apple-App-Info") == "com.apple.gs.xcode.auth", "Lookup omitted compatibility headers")
    try expectRedacted(rig.log.text())
}

func testTrustedLookupURLs() throws {
    for url in ["https://gsa.apple.com/service", "https://gsa-alt.apple.com:443/service", "HTTPS://GSA.APPLE.COM/service"] {
        try expect(AppleAuthenticationTransport.trustedServiceURL(url) != nil, "Trusted HTTPS URL was rejected")
    }
    for url in [
        "http://gsa.apple.com/service", "https://apple.com.attacker.invalid/service",
        "https://attacker.invalid/apple.com", "https://notapple.com/service",
        "https://gsa.apple.com:8443/service", "https://user@gsa.apple.com/service",
        "https://user:private-password@gsa.apple.com/service", "https://gsa.apple.com/service#fragment",
        "file:///service", "relative/service"
    ] {
        try expect(AppleAuthenticationTransport.trustedServiceURL(url) == nil, "Untrusted lookup URL was accepted")
    }
}

func testFailedLookupIsNotCached() async throws {
    let good = "https://gsa.apple.com/recovered"
    for bad in [MockReply(status: 503), try lookupReply("https://attacker.invalid/private-token"), MockReply(data: Data())] {
        let rig = Rig(.iloader, replies: [bad, try lookupReply(good)])
        defer { rig.session.invalidateAndCancel() }
        do {
            _ = try await rig.transport.authenticationURL()
            throw TestFailure(description: "Invalid lookup succeeded")
        } catch let error as AppleAuthenticationRequestError {
            try expect(error.stage == "lookup" && error.mode == .iloader, "Lookup error lost context")
            try expectRedacted(error.localizedDescription)
        }
        let recovered = try await rig.transport.authenticationURL()
        try expect(recovered.absoluteString == good, "Failed lookup poisoned the cache")
        try expect(MockURLProtocol.state.recordedRequests().count == 2, "Failed lookup did not retry")
        try expectRedacted(rig.log.text())
    }
}

func testServiceErrorsAreSafeAndStaged() async throws {
    let html = Data(("<html>503 " + secrets.joined(separator: " ") + "</html>").utf8)
    for mode in [AppleAuthenticationMode.standard, .iloader] {
        for stage in [AppleAuthenticationStage.initialize, .complete, .appTokens, .developerAccount] {
            let rig = Rig(mode, replies: [MockReply(status: 503, data: html)])
            defer { rig.session.invalidateAndCancel() }
            do {
                _ = try await rig.transport.send(authenticationRequest(mode, stage: stage), stage: stage)
                throw TestFailure(description: "503 response was accepted")
            } catch let error as AppleAuthenticationRequestError {
                try expect(error.stage == stage.rawValue && error.mode == mode && error.statusCode == 503, "503 error lost stage, mode, or status")
                try expect(error.localizedDescription.contains("HTTP 503"), "503 status is missing from user error")
                try expectRedacted(error.localizedDescription)
            }
            let logs = rig.log.text()
            try expect(logs.contains("stage=\(stage.rawValue)") && logs.contains("status=503"), "503 diagnostics omitted stage or status")
            try expectRedacted(logs)
        }
    }
}

func testResponseClassification() async throws {
    let cases: [(Data, String)] = [
        (Data(), "empty"), (Data("<html>private-token</html>".utf8), "other"),
        (try PropertyListSerialization.data(fromPropertyList: ["ok": true], format: .xml, options: 0), "plist"),
        (Data("{\"message\":\"ok\"}".utf8), "json")
    ]
    for (body, format) in cases {
        let rig = Rig(.standard, replies: [MockReply(data: body)])
        defer { rig.session.invalidateAndCancel() }
        let (returned, response) = try await rig.transport.send(authenticationRequest(.standard, stage: .complete), stage: .complete)
        try expect(returned == body && response.statusCode == 200, "Transport changed successful response data")
        try expect(AppleAuthenticationTransport.responseFormat(returned) == format, "Response format classification failed")
        try expect(rig.log.text().contains("format=\(format)"), "Response log omitted format")
        try expectRedacted(rig.log.text())
    }
}

func testApple401RemainsAvailable() async throws {
    let body = try PropertyListSerialization.data(fromPropertyList: ["Status": ["ec": -22406, "em": "private-token"]], format: .xml, options: 0)
    let rig = Rig(.standard, replies: [MockReply(status: 401, data: body)])
    defer { rig.session.invalidateAndCancel() }
    let (returned, response) = try await rig.transport.send(authenticationRequest(.standard, stage: .complete), stage: .complete)
    try expect(returned == body && response.statusCode == 401, "Apple 401 payload was hidden from the caller")
    let parsed = try PropertyListSerialization.propertyList(from: returned, format: nil) as? [String: Any]
    let status = parsed?["Status"] as? [String: Any]
    try expect(status?["ec"] as? Int == -22406, "Apple credential error was lost")
    do {
        try AppleAuthenticationTransport.requireSuccess(response, stage: .complete, mode: .standard)
        throw TestFailure(description: "requireSuccess accepted HTTP 401")
    } catch let error as AppleAuthenticationRequestError {
        try expect(error.statusCode == 401 && error.stage == "complete", "HTTP rejection lost status or stage")
        try expectRedacted(error.localizedDescription)
    }
    try expectRedacted(rig.log.text())
}

func testStructuredAppleErrorsArePreserved() async throws {
    let cases: [(Int, AppleAuthenticationStage, [String: Any])] = [
        (429, .verifyTrustedCode, ["ec": -21668, "em": "private-token"]),
        (429, .requestPhoneCode, ["Status": ["ec": -20102, "em": "private-token"]]),
        (503, .complete, ["Response": ["Status": ["ec": -22416, "em": "private-token"]]]),
        (503, .developerAccount, ["resultCode": 1100, "resultString": "private-token"]),
        (503, .developerAccount, ["errors": [["detail": "private-token"]]])
    ]
    for mode in [AppleAuthenticationMode.standard, .iloader] {
        for (httpStatus, stage, payload) in cases {
            for useJSON in [false, true] {
                let body: Data
                if useJSON {
                    body = try JSONSerialization.data(withJSONObject: payload)
                } else {
                    body = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
                }
                let rig = Rig(mode, replies: [MockReply(status: httpStatus, data: body)])
                defer { rig.session.invalidateAndCancel() }
                let (returned, response) = try await rig.transport.send(authenticationRequest(mode, stage: stage), stage: stage)
                try expect(returned == body && response.statusCode == httpStatus, "Structured Apple error was replaced or changed")
                try expect(AppleAuthenticationTransport.hasAppleError(returned), "Structured Apple error was not recognized")
                try expectRedacted(rig.log.text())
            }
        }
    }

    let nonErrors: [[String: Any]] = [
        ["Status": ["ec": 0]], ["resultCode": 0], ["errors": [] as [String]], ["message": "private-token"]
    ]
    for payload in nonErrors {
        let body = try JSONSerialization.data(withJSONObject: payload)
        let rig = Rig(.standard, replies: [MockReply(status: 503, data: body)])
        defer { rig.session.invalidateAndCancel() }
        do {
            _ = try await rig.transport.send(authenticationRequest(.standard, stage: .complete), stage: .complete)
            throw TestFailure(description: "503 without an Apple error was accepted")
        } catch let error as AppleAuthenticationRequestError {
            try expect(error.statusCode == 503 && error.stage == "complete", "Unstructured 503 lost context")
            try expectRedacted(error.localizedDescription)
        }
        try expectRedacted(rig.log.text())
    }
}

func testRedirectPolicy() throws {
    let rig = Rig(.standard, replies: [])
    defer { rig.session.invalidateAndCancel() }
    let original = try authenticationRequest(.standard, stage: .complete)
    let task = rig.session.dataTask(with: original)
    defer { task.cancel() }
    let policy = AppleAuthenticationRedirectPolicy()
    let destinations: [(String, Bool)] = [
        ("https://gsa.apple.com/redirect", true),
        ("https://gsa-alt.apple.com:443/redirect?value=private-query", true),
        ("http://gsa.apple.com/redirect", false),
        ("https://attacker.invalid/redirect", false),
        ("https://gsa.apple.com.attacker.invalid/redirect", false),
        ("https://user:private-password@gsa.apple.com/redirect", false)
    ]
    for status in [307, 308] {
        let response = HTTPURLResponse(url: original.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: [:])!
        for (destination, allowed) in destinations {
            var redirected = original
            redirected.url = URL(string: destination)!
            let decision = RedirectDecision()
            policy.urlSession(rig.session, task: task, willPerformHTTPRedirection: response,
                              newRequest: redirected) { decision.record($0) }
            let (calls, accepted) = decision.snapshot()
            try expect(calls == 1, "Redirect completion was not called exactly once")
            if allowed {
                try expect(accepted == redirected, "Trusted redirect changed or dropped the request")
            } else {
                try expect(accepted == nil, "Unsafe redirect was accepted")
            }
        }
    }
    try expect(MockURLProtocol.state.recordedRequests().isEmpty, "Redirect policy sent a target request")
}

func testCancellationIsPreserved() async throws {
    let rig = Rig(.standard, replies: [MockReply(error: URLError(.cancelled))])
    defer { rig.session.invalidateAndCancel() }
    do {
        _ = try await rig.transport.send(authenticationRequest(.standard, stage: .initialize), stage: .initialize)
        throw TestFailure(description: "Cancelled request succeeded")
    } catch let error as URLError {
        try expect(error.code == .cancelled, "Cancellation was replaced with another URL error")
    }
    try expect(!rig.log.text().contains("network-error"), "Cancellation was logged as a network failure")
    try expectRedacted(rig.log.text())
}

func testNetworkErrorsAreRedacted() async throws {
    let underlying = URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: secrets.joined(separator: " ")])
    let rig = Rig(.iloader, replies: [MockReply(error: underlying)])
    defer { rig.session.invalidateAndCancel() }
    do {
        _ = try await rig.transport.send(authenticationRequest(.iloader, stage: .appTokens), stage: .appTokens)
        throw TestFailure(description: "Network failure succeeded")
    } catch let error as AppleAuthenticationRequestError {
        try expect(error.stage == "apptokens" && error.mode == .iloader && error.statusCode == nil, "Network error lost request context")
        try expectRedacted(error.localizedDescription)
    }
    try expectRedacted(rig.log.text())
}

func developerBaseHeaders(contentType: String, accept: String) -> [String: String] {
    [
        "Content-Type": contentType, "Accept": accept, "Accept-Language": "en-us",
        "User-Agent": "original-developer-agent", "X-MMe-Client-Info": "original-developer-client",
        "X-Xcode-Version": "original-xcode", "X-Apple-App-Info": "original-app-info",
        "X-Apple-GS-Token": "private-token", "X-Apple-I-Identity-Id": "private-dsid",
        "X-Apple-I-MD": "private-md", "X-Apple-I-MD-M": "private-machine",
        "X-Mme-Device-Id": "private-device", "X-Apple-I-MD-RINFO": "17106176",
        "X-Apple-Locale": "zh_CN", "X-API-Custom": "private-api-header"
    ]
}

func testDeveloperIdentityAcrossRequests() async throws {
    let endpoints: [(String, Bool, String, String)] = [
        ("https://developerservices2.apple.com/services/QH65B2/viewDeveloper.action", false, "text/x-xml-plist", "text/x-xml-plist"),
        ("https://developerservices2.apple.com/services/QH65B2/listTeams.action", false, "text/x-xml-plist", "text/x-xml-plist"),
        ("https://developerservices2.apple.com/services/QH65B2/ios/listAllDevelopmentCerts.action", false, "text/x-xml-plist", "text/x-xml-plist"),
        ("https://developerservices2.apple.com/services/v1/profiles", true, "application/vnd.api+json", "application/vnd.api+json")
    ]
    let identityFields: Set<String> = ["User-Agent", "X-MMe-Client-Info", "X-Xcode-Version", "X-Apple-App-Info"]
    for mode in [AppleAuthenticationMode.standard, .iloader] {
        let rig = Rig(mode, replies: Array(repeating: MockReply(), count: endpoints.count + 1))
        defer { rig.session.invalidateAndCancel() }
        _ = try await rig.transport.send(authenticationRequest(mode, stage: .initialize), stage: .initialize)
        for (address, services, contentType, accept) in endpoints {
            let url = URL(string: address)!
            let original = developerBaseHeaders(contentType: contentType, accept: accept)
            let headers = mode.developerHeaders(original)
            if mode == .standard {
                try expect(headers == original, "Standard developer headers changed")
            } else {
                try expect(Set(headers.keys) == Set(original.keys), "Compatibility policy added or dropped unrelated headers")
                for (key, value) in original where !identityFields.contains(key) {
                    try expect(headers[key] == value, "Compatibility policy changed developer API header: \(key)")
                }
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            _ = try await rig.transport.send(request, stage: .developerOperation(url, services: services))
        }
        let requests = MockURLProtocol.state.recordedRequests()
        try expect(requests.count == endpoints.count + 1, "Missing authentication or developer request")
        let authentication = requests[0]
        for (index, endpoint) in endpoints.enumerated() {
            let (address, _, contentType, accept) = endpoint
            let sent = requests[index + 1]
            try expect(sent.url?.absoluteString == address, "Developer request used the wrong endpoint")
            let original = developerBaseHeaders(contentType: contentType, accept: accept)
            for (key, value) in original {
                let expected = mode == .iloader && identityFields.contains(key)
                    ? authentication.value(forHTTPHeaderField: key) : value
                try expect(sent.value(forHTTPHeaderField: key) == expected, "Developer request changed profile or API header: \(key)")
            }
            try expect(sent.value(forHTTPHeaderField: "Connection") != "close", "Developer request inherited the SRP complete connection header")
        }
        try expectRedacted(rig.log.text())
    }
}

func testDeveloperStagesAndTeams1100() async throws {
    let teamURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/listTeams.action?value=private-query")!
    let accountURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/viewDeveloper.action?clientId=private-query")!
    let certificateURL = URL(string: "https://developerservices2.apple.com/services/QH65B2/ios/submitDevelopmentCSR.action")!
    let profilesURL = URL(string: "https://developerservices2.apple.com/services/v1/profiles")!
    try expect(AppleAuthenticationStage.developerOperation(teamURL) == .developerTeams, "listTeams stage was not recognized")
    try expect(AppleAuthenticationStage.developerOperation(accountURL) == .developerAccount, "viewDeveloper stage was not recognized")
    try expect(AppleAuthenticationStage.developerOperation(certificateURL) == .developerRequest, "Certificate request did not use the general developer stage")
    try expect(AppleAuthenticationStage.developerOperation(profilesURL, services: true) == .developerServices, "JSON services request did not use the services stage")
    try expect(AppleAuthenticationStage.developerOperation(accountURL, services: true) == .developerServices, "Explicit services mode did not take precedence")

    let body = try PropertyListSerialization.data(
        fromPropertyList: ["resultCode": 1100, "resultString": "private-token"], format: .xml, options: 0
    )
    for mode in [AppleAuthenticationMode.standard, .iloader] {
        let rig = Rig(mode, replies: [MockReply(status: 200, data: body)])
        defer { rig.session.invalidateAndCancel() }
        var request = URLRequest(url: teamURL)
        request.httpMethod = "POST"
        mode.developerHeaders(developerBaseHeaders(contentType: "text/x-xml-plist", accept: "text/x-xml-plist")).forEach {
            request.setValue($1, forHTTPHeaderField: $0)
        }
        let stage = AppleAuthenticationStage.developerOperation(teamURL)
        let (returned, response) = try await rig.transport.send(request, stage: stage)
        try expect(returned == body && response.statusCode == 200, "listTeams 1100 response was hidden or converted into a transport error")
        let parsed = try PropertyListSerialization.propertyList(from: returned, format: nil) as? [String: Any]
        try expect(parsed?["resultCode"] as? Int == 1100, "Apple resultCode 1100 was lost")
        try AppleAuthenticationTransport.requireSuccess(response, stage: stage, mode: mode)
        let requests = MockURLProtocol.state.recordedRequests()
        try expect(requests.count == 1 && requests[0].value(forHTTPHeaderField: "X-Apple-GS-Token") == "private-token", "listTeams request lost its GS token")
        let logs = rig.log.text()
        try expect(logs.contains("stage=listTeams") && logs.contains("status=200"), "listTeams diagnostics lost stage or HTTP status")
        try expect(!logs.contains("status=503"), "listTeams business error was reported as HTTP 503")
        try expectRedacted(logs)
    }
}

@main
struct AppleAuthTests {
    static func main() async throws {
        let tests: [(String, @Sendable () async throws -> Void)] = [
            ("standard policy and serialization", testStandardPolicy),
            ("iLoader policy and request-local connection header", testIloaderPolicyAndConnections),
            ("lookup routing and successful cache", testLookupAndCache),
            ("trusted HTTPS lookup boundaries", { try testTrustedLookupURLs() }),
            ("failed lookup recovery without caching", testFailedLookupIsNotCached),
            ("safe 503 errors by mode and stage", testServiceErrorsAreSafeAndStaged),
            ("empty, unknown, plist, and JSON classification", testResponseClassification),
            ("Apple 401 payload and explicit success requirement", testApple401RemainsAvailable),
            ("structured Apple errors survive HTTP 429 and 503", testStructuredAppleErrorsArePreserved),
            ("trusted HTTPS redirects preserve only allowed requests", { try testRedirectPolicy() }),
            ("cancellation preservation", testCancellationIsPreserved),
            ("network error redaction", testNetworkErrorsAreRedacted),
            ("consistent developer identity with preserved API headers", testDeveloperIdentityAcrossRequests),
            ("developer stages and listTeams HTTP 200 resultCode 1100", testDeveloperStagesAndTeams1100)
        ]
        for (name, test) in tests {
            try await test()
            print("PASS: \(name)")
        }
        print("Passed \(tests.count) authentication protocol tests")
    }
}
