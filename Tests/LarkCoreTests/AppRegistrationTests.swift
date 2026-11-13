import Foundation
import Testing
@testable import LarkCore
#if canImport(zlib)
import zlib
#endif

// Ports node-sdk scene/registration/__tests__/register-app.ts and __tests__/addons.ts, plus
// coverage of the polling state machine, the wire format and the failure paths.

// MARK: - Test doubles

/// Scripted transport: each request consumes the next step; when the script is exhausted the
/// fallback answers (a terminal `expired_token` by default, so a stray poll loop always ends).
private final class RegistrationHTTP: LarkHTTPClient, @unchecked Sendable {
    enum Step {
        case response(LarkHTTPResponse)
        case failure(any Error)
        case gate(Gate)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var _requests: [LarkHTTPRequest] = []
    private let fallback: @Sendable (LarkHTTPRequest) -> LarkHTTPResponse

    init(
        _ steps: [Step],
        fallback: @escaping @Sendable (LarkHTTPRequest) -> LarkHTTPResponse = { _ in json(["error": "expired_token"]) }
    ) {
        self.steps = steps
        self.fallback = fallback
    }

    var requests: [LarkHTTPRequest] { lock.withLock { _requests } }

    func send(_ request: LarkHTTPRequest) async throws -> LarkHTTPResponse {
        let step: Step? = lock.withLock {
            _requests.append(request)
            return steps.isEmpty ? nil : steps.removeFirst()
        }
        switch step {
        case nil: return fallback(request)
        case .response(let r)?: return r
        case .failure(let e)?: throw e
        case .gate(let g)?: return await g.wait()
        }
    }
}

/// A response the test releases by hand; ignores cancellation like a slow server.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var response: LarkHTTPResponse?
    private var waiters: [CheckedContinuation<LarkHTTPResponse, Never>] = []

    func wait() async -> LarkHTTPResponse {
        await withCheckedContinuation { (c: CheckedContinuation<LarkHTTPResponse, Never>) in
            let ready: LarkHTTPResponse? = lock.withLock {
                if let response { return response }
                waiters.append(c)
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }

    func open(_ r: LarkHTTPResponse) {
        let pending: [CheckedContinuation<LarkHTTPResponse, Never>] = lock.withLock {
            response = r
            defer { waiters = [] }
            return waiters
        }
        for c in pending { c.resume(returning: r) }
    }
}

private final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T] = []
    func append(_ v: T) { lock.withLock { _values.append(v) } }
    func removeAll() { lock.withLock { _values.removeAll() } }
    var values: [T] { lock.withLock { _values } }
}

/// Lets a callback cancel the task running `registerApp` (node-sdk: `controller.abort()`),
/// even if it fires before the task handle is stored.
private final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<RegisterAppResult, any Error>?
    private var requested = false

    func set(_ t: Task<RegisterAppResult, any Error>) {
        let cancelNow = lock.withLock { task = t; return requested }
        if cancelNow { t.cancel() }
    }

    func cancel() {
        let t = lock.withLock { requested = true; return task }
        t?.cancel()
    }
}

private func json(_ value: JSONValue, status: Int = 200) -> LarkHTTPResponse {
    LarkHTTPResponse(statusCode: status, headers: ["Content-Type": "application/json"], body: Data(value.jsonString().utf8))
}

private let fakeBeginJSON: JSONValue = [
    "device_code": "dev-1",
    "verification_uri_complete": "https://accounts.feishu.cn/page/launcher",
    "verification_uri": "https://accounts.feishu.cn/page/launcher",
    "user_code": "uc-1",
    "interval": 5,
    "expires_in": 600,
]

private func fakeBegin(interval: JSONValue = 5, expiresIn: JSONValue = 600) -> LarkHTTPResponse {
    guard case .object(var o) = fakeBeginJSON else { fatalError() }
    o["interval"] = interval
    o["expires_in"] = expiresIn
    return json(.object(o))
}

/// Poll delays are recorded and skipped; the expiry timer never fires unless overridden.
private func testTimers(
    delays: Recorder<Double> = Recorder(),
    expiry: @escaping @Sendable (Double) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }
) -> AppRegistration.Timers {
    AppRegistration.Timers(
        pollDelay: { ms in
            delays.append(ms)
            await Task.yield()
        },
        expiry: expiry)
}

private func options(
    _ http: RegistrationHTTP,
    domain: String? = nil,
    larkDomain: String? = nil,
    source: String? = nil,
    appPreset: AppPreset? = nil,
    addons: AppAddons? = nil,
    appId: String? = nil,
    createOnly: Bool? = nil,
    onStatusChange: (@Sendable (StatusChangeInfo) -> Void)? = nil,
    onQRCodeReady: @escaping @Sendable (QRCodeInfo) -> Void = { _ in }
) -> RegisterAppOptions {
    RegisterAppOptions(
        domain: domain, larkDomain: larkDomain, source: source, appPreset: appPreset, addons: addons, appId: appId,
        createOnly: createOnly, httpClient: http, onStatusChange: onStatusChange, onQRCodeReady: onQRCodeReady)
}

/// Drives `registerApp` just far enough to capture the QR-code URL, then cancels the task from
/// `onQRCodeReady` (node-sdk aborts its controller there). Returns the URL's query.
private func captureQRURL(
    source: String? = nil,
    appPreset: AppPreset? = nil,
    addons: AppAddons? = nil,
    appId: String? = nil,
    createOnly: Bool? = nil
) async throws -> (url: String, query: FormURLEncoded) {
    let http = RegistrationHTTP([.response(fakeBegin())])
    let captured = Recorder<String>()
    let box = CancelBox()
    let opts = options(
        http, source: source, appPreset: appPreset, addons: addons, appId: appId, createOnly: createOnly,
        onQRCodeReady: { info in
            captured.append(info.url)
            box.cancel()
        })
    let task = Task { try await AppRegistration.register(opts, timers: testTimers()) }
    box.set(task)
    await #expect(throws: RegisterAppError(code: .abort, description: "Registration was aborted")) { try await task.value }
    #expect(http.requests.count == 1)  // only `begin`: the abort is seen before the first poll
    let url = try #require(captured.values.first)
    let query = try #require(SearchParamsURL(url)).query
    return (url, query)
}

/// Runs `registerApp` and returns the `invalidArgument` message it throws.
private func invalidArgumentMessage(_ opts: (RegistrationHTTP) -> RegisterAppOptions) async -> String? {
    let http = RegistrationHTTP([.response(fakeBegin())])
    let qrShown = Recorder<Bool>()
    var o = opts(http)
    o.onQRCodeReady = { _ in qrShown.append(true) }
    do {
        _ = try await AppRegistration.register(o, timers: testTimers())
    } catch LarkError.invalidArgument(let message) {
        #expect(qrShown.values.isEmpty)  // "should never fire"
        return message
    } catch {
        Issue.record("unexpected error \(error)")
    }
    return nil
}

private func addonsErrorMessage(_ addons: JSONValue) -> String? {
    do {
        _ = try AddonsEncoder.encode(addons)
    } catch LarkError.invalidArgument(let message) {
        return message
    } catch {
        Issue.record("unexpected error \(error)")
    }
    return nil
}

private func addonsErrorMessage(_ addons: AppAddons) -> String? { addonsErrorMessage(addons.jsonValue) }

private func formBody(_ request: LarkHTTPRequest) -> String {
    String(decoding: request.body ?? Data(), as: UTF8.self)
}

private let hasZlib: Bool = {
    #if canImport(zlib)
    return true
    #else
    return false
    #endif
}()

/// Mirror of the landing page's decode chain: base64url → gunzip → JSON.parse.
private func decodeAddons(_ encoded: String) throws -> JSONValue {
    var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 { base64 += "=" }
    let gz = try #require(Data(base64Encoded: base64))
    return try JSONValue(data: Data(try gunzip(Array(gz))))
}

private func gunzip(_ input: [UInt8]) throws -> [UInt8] {
    #if canImport(zlib)
    var stream = z_stream()
    guard inflateInit2_(&stream, 31, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw LarkError.unsupported("inflateInit2 failed")
    }
    defer { inflateEnd(&stream) }
    var out: [UInt8] = []
    var input = input
    var chunk = [UInt8](repeating: 0, count: 16_384)
    var status: Int32 = Z_OK
    input.withUnsafeMutableBufferPointer { inp in
        stream.next_in = inp.baseAddress
        stream.avail_in = uInt(inp.count)
        repeat {
            chunk.withUnsafeMutableBufferPointer { buf in
                stream.next_out = buf.baseAddress
                stream.avail_out = uInt(buf.count)
                status = inflate(&stream, Z_NO_FLUSH)
                out += buf[0..<(buf.count - Int(stream.avail_out))]
            }
        } while status == Z_OK
    }
    guard status == Z_STREAM_END else { throw LarkError.unsupported("inflate failed: \(status)") }
    return out
    #else
    throw LarkError.unsupported("zlib unavailable")
    #endif
}

/// Waits (up to ~2s) until `condition` holds.
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<2000 where !condition() {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// Full addons used by node-sdk's round-trip tests.
private let fullAddons = AppAddons(
    scopes: .init(tenant: ["im:message:send_as_bot", "drive:drive.metadata:readonly"], user: ["calendar:calendar:read"]),
    events: .init(items: .init(tenant: ["im.message.receive_v1"], user: ["calendar.calendar.event.changed_v4"])),
    callbacks: .init(items: ["card.action.trigger"]))

/// Parent suite so `swift test --filter AppRegistrationTests` selects every case below.
@Suite enum AppRegistrationTests {}

extension AppRegistrationTests {
    // MARK: - registerApp appPreset (node: describe('registerApp appPreset'))

    @Suite struct RegisterAppPresetTests {
        @Test func omitsAvatarNameDescWhenAppPresetIsNotProvided() async throws {
            let q = try await captureQRURL().query
            #expect(!q.has("avatar"))
            #expect(!q.has("name"))
            #expect(!q.has("desc"))
            // Existing params still set
            #expect(q.get("from") == "sdk")
            #expect(q.get("source") == "node-sdk")
            #expect(q.get("tp") == "sdk")
        }

        @Test func acceptsASingleAvatarString() async throws {
            let q = try await captureQRURL(appPreset: AppPreset(avatar: "https://example.com/a.png")).query
            #expect(q.getAll("avatar") == ["https://example.com/a.png"])
        }

        @Test func acceptsAnArrayOfAvatarsAndPreservesOrder() async throws {
            let avatars = ["https://example.com/a.png", "https://example.com/b.webp", "https://example.com/c.gif"]
            let q = try await captureQRURL(appPreset: AppPreset(avatar: avatars)).query
            #expect(q.getAll("avatar") == avatars)
        }

        @Test func acceptsExactlySixAvatars() async throws {
            let six = (0..<6).map { "https://example.com/\($0).png" }
            let q = try await captureQRURL(appPreset: AppPreset(avatar: six)).query
            #expect(q.getAll("avatar") == six)
        }

        @Test func urlEncodesNameIncludingUserPlaceholder() async throws {
            let (url, q) = try await captureQRURL(appPreset: AppPreset(name: "{user}的应用"))
            #expect(q.get("name") == "{user}的应用")
            // Raw string form must keep the percent-encoded value
            #expect(url.contains("name=%7Buser%7D%E7%9A%84%E5%BA%94%E7%94%A8"))
        }

        @Test func urlEncodesDesc() async throws {
            let q = try await captureQRURL(appPreset: AppPreset(desc: "由业务平台自动生成")).query
            #expect(q.get("desc") == "由业务平台自动生成")
        }

        @Test func emitsAllThreeFieldsTogether() async throws {
            let q = try await captureQRURL(
                appPreset: AppPreset(avatar: ["https://example.com/a.png", "https://example.com/b.png"], name: "MyApp", desc: "demo")
            ).query
            #expect(q.getAll("avatar").count == 2)
            #expect(q.get("name") == "MyApp")
            #expect(q.get("desc") == "demo")
        }

        @Test func doesNotInterfereWithTheSourceParameter() async throws {
            let q = try await captureQRURL(source: "lark-cli", appPreset: AppPreset(name: "X")).query
            #expect(q.get("source") == "node-sdk/lark-cli")
            #expect(q.get("name") == "X")
        }
    }

    // MARK: - registerApp appPreset validation

    @Suite struct RegisterAppPresetValidationTests {
        @Test func throwsWhenAvatarIsAnEmptyArray() async {
            let m = await invalidArgumentMessage { options($0, appPreset: AppPreset(avatar: [String]())) }
            #expect(m == "appPreset.avatar must contain at least 1 URL")
        }

        @Test func throwsWhenAvatarHasMoreThanSixEntries() async {
            let seven = (0..<7).map { "https://example.com/\($0).png" }
            let m = await invalidArgumentMessage { options($0, appPreset: AppPreset(avatar: seven)) }
            #expect(m == "appPreset.avatar supports at most 6 URLs, got 7")
        }

        @Test func throwsWhenAvatarIsAnEmptyString() async {
            let m = await invalidArgumentMessage { options($0, appPreset: AppPreset(avatar: "")) }
            #expect(m == "appPreset.avatar[0] must be a non-empty string")
        }

        @Test func throwsWhenAnAvatarArrayEntryIsEmptyIncludingItsIndex() async {
            let m = await invalidArgumentMessage { options($0, appPreset: AppPreset(avatar: ["https://example.com/a.png", ""])) }
            #expect(m == "appPreset.avatar[1] must be a non-empty string")
        }
    }

    // MARK: - registerApp addons

    @Suite struct RegisterAppAddonsTests {
        @Test func omitsTheAddonsParamWhenNotProvided() async throws {
            #expect(!(try await captureQRURL().query.has("addons")))
        }

        @Test(.enabled(if: hasZlib)) func encodesAddonsIntoAURLSafeParamThatDecodesBackToTheInput() async throws {
            let q = try await captureQRURL(addons: fullAddons).query
            let encoded = try #require(q.get("addons"))
            #expect(encoded.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
            #expect(try decodeAddons(encoded) == fullAddons.jsonValue)
        }

        @Test(.enabled(if: hasZlib)) func coexistsWithAppPresetAndCreateOnly() async throws {
            let q = try await captureQRURL(
                appPreset: AppPreset(name: "MyApp"),
                addons: AppAddons(scopes: .init(tenant: ["im:message:send_as_bot"])),
                createOnly: true
            ).query
            #expect(try decodeAddons(try #require(q.get("addons"))) == ["scopes": ["tenant": ["im:message:send_as_bot"]]])
            #expect(q.get("name") == "MyApp")
            #expect(q.get("createOnly") == "true")
        }

        @Test func rejectsBeforeShowingTheQRCodeWhenAddonsIsInvalid() async {
            let m = await invalidArgumentMessage { options($0, addons: AppAddons()) }
            #expect(m == "addons must contain at least one scope, event or callback")
        }
    }

    // MARK: - registerApp appId (update flow)

    @Suite struct RegisterAppAppIdTests {
        @Test func omitsTheClientIDParamWhenAppIdIsNotProvided() async throws {
            #expect(!(try await captureQRURL().query.has("clientID")))
        }

        @Test func setsClientIDToTheGivenAppId() async throws {
            #expect(try await captureQRURL(appId: "cli_a1b2c3").query.get("clientID") == "cli_a1b2c3")
        }

        @Test func combinesWithAddonsForAConfigUpdateLink() async throws {
            let q = try await captureQRURL(addons: AppAddons(scopes: .init(tenant: ["im:message:send_as_bot"])), appId: "cli_a1b2c3").query
            #expect(q.get("clientID") == "cli_a1b2c3")
            #expect(q.has("addons"))
        }

        @Test func rejectsAnEmptyAppId() async {
            let m = await invalidArgumentMessage { options($0, appId: "") }
            #expect(m == "appId must be a non-empty string")
        }

        @Test func emptyAppIdIsRejectedBeforeAnyRequest() async {
            let http = RegistrationHTTP([.response(fakeBegin())])
            await #expect(throws: LarkError.self) { try await AppRegistration.register(options(http, appId: ""), timers: testTimers()) }
            #expect(http.requests.isEmpty)
        }
    }

    // MARK: - registerApp createOnly

    @Suite struct RegisterAppCreateOnlyTests {
        @Test func omitsTheCreateOnlyParamWhenNotProvided() async throws {
            #expect(!(try await captureQRURL().query.has("createOnly")))
        }

        @Test func setsCreateOnlyTrueWhenEnabled() async throws {
            #expect(try await captureQRURL(createOnly: true).query.get("createOnly") == "true")
        }

        @Test func omitsTheCreateOnlyParamWhenExplicitlyFalse() async throws {
            #expect(!(try await captureQRURL(createOnly: false).query.has("createOnly")))
        }
    }

    // MARK: - registerApp cancellation

    @Suite struct RegisterAppCancellationTests {
        @Test func doesNotResumePollingWhenAnInFlightRequestResolvesAfterAbort() async throws {
            let gate = Gate()
            let http = RegistrationHTTP([
                .response(fakeBegin(interval: 0)),
                .gate(gate),
                // Never consumed while the fix holds; a regression would hit this terminal answer.
                .response(json(["error": "expired_token"])),
            ])
            let statuses = Recorder<StatusChangeInfo>()
            let delays = Recorder<Double>()
            let opts = options(http, onStatusChange: { statuses.append($0) })
            let registration = Task { try await AppRegistration.register(opts, timers: testTimers(delays: delays)) }

            await waitUntil { http.requests.count == 2 }
            #expect(http.requests.count == 2)

            registration.cancel()
            await #expect(throws: RegisterAppError(code: .abort, description: "Registration was aborted")) {
                try await registration.value
            }

            // Only activity that happens *after* the abort matters from here on.
            statuses.removeAll()
            gate.open(json(["error": "authorization_pending"]))
            try await Task.sleep(for: .milliseconds(20))

            #expect(http.requests.count == 2)
            #expect(statuses.values.isEmpty)
            #expect(delays.values.isEmpty)  // no poll was scheduled
        }

        @Test func doesNotArmAPollTimerWhenOnStatusChangeAbortsSynchronously() async throws {
            let http = RegistrationHTTP([
                .response(fakeBegin(interval: 0)),
                .response(json(["error": "authorization_pending"])),
            ])
            let delays = Recorder<Double>()
            let box = CancelBox()
            // Aborting from inside the callback runs the whole teardown while the poll loop is
            // still on the stack, so anything scheduled afterwards would outlive it.
            let opts = options(http, onStatusChange: { _ in box.cancel() })
            let registration = Task { try await AppRegistration.register(opts, timers: testTimers(delays: delays)) }
            box.set(registration)

            await #expect(throws: RegisterAppError(code: .abort, description: "Registration was aborted")) {
                try await registration.value
            }
            try await Task.sleep(for: .milliseconds(20))
            #expect(delays.values.isEmpty)  // the timer queue stayed empty
            #expect(http.requests.count == 2)
        }

        @Test func cancellationBeforeTheCallStillCompletesBeginLikeNode() async throws {
            // node-sdk passes no signal to `begin`: the QR code is shown, then the abort is observed.
            let http = RegistrationHTTP([.response(fakeBegin())])
            let shown = Recorder<String>()
            let opts = options(http, onQRCodeReady: { shown.append($0.url) })
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await AppRegistration.register(opts, timers: testTimers())
            }
            await #expect(throws: RegisterAppError(code: .abort, description: "Registration was aborted")) { try await task.value }
            #expect(shown.values.count == 1)
            #expect(http.requests.count == 1)
        }

        @Test func cancellationDuringThePollDelayAborts() async throws {
            let http = RegistrationHTTP([.response(fakeBegin())], fallback: { _ in json(["error": "authorization_pending"]) })
            let statuses = Recorder<StatusChangeInfo>()
            let timers = AppRegistration.Timers(
                pollDelay: { _ in try await Task.sleep(for: .seconds(3600)) },
                expiry: { _ in try await Task.sleep(for: .seconds(3600)) })
            let opts = options(http, onStatusChange: { statuses.append($0) })
            let task = Task { try await AppRegistration.register(opts, timers: timers) }
            await waitUntil { statuses.values.count == 1 }
            task.cancel()
            await #expect(throws: RegisterAppError(code: .abort, description: "Registration was aborted")) { try await task.value }
            #expect(http.requests.count == 2)
        }
    }

    // MARK: - Polling state machine and wire format

    @Suite struct RegisterAppFlowTests {
        @Test func beginAndPollWireFormat() async throws {
            let http = RegistrationHTTP([
                .response(fakeBegin()),
                .response(json(["client_id": "cli_new", "client_secret": "sec", "user_info": ["open_id": "ou_1", "tenant_brand": "feishu"]])),
            ])
            let result = try await AppRegistration.register(options(http), timers: testTimers())
            #expect(result == RegisterAppResult(clientId: "cli_new", clientSecret: "sec", userInfo: .init(openId: "ou_1", tenantBrand: "feishu")))

            let reqs = http.requests
            #expect(reqs.count == 2)
            for r in reqs {
                #expect(r.method == .post)
                #expect(r.url.absoluteString == "https://accounts.feishu.cn/oauth/v1/app/registration")
                #expect(r.headers["Content-Type"] == "application/x-www-form-urlencoded")
                #expect(r.headers["User-Agent"]?.hasPrefix("oapi-swift-sdk/") == true)
                #expect(r.headers["Authorization"] == nil)
            }
            // Produced by node: new URLSearchParams({action:'begin',archetype:'PersonalAgent',
            //   auth_method:'client_secret',request_user_info:'open_id'}).toString()
            #expect(formBody(reqs[0]) == "action=begin&archetype=PersonalAgent&auth_method=client_secret&request_user_info=open_id")
            #expect(formBody(reqs[1]) == "action=poll&device_code=dev-1")
        }

        @Test func pollBodyIsFormEncodedLikeURLSearchParams() async throws {
            let begin: JSONValue = ["device_code": "dev+1/=~ x&é*", "verification_uri_complete": "https://accounts.feishu.cn/page/launcher"]
            let http = RegistrationHTTP([.response(json(begin)), .response(json(["error": "access_denied"]))])
            await #expect(throws: RegisterAppError.self) { try await AppRegistration.register(options(http), timers: testTimers()) }
            // Produced by node: new URLSearchParams({action:'poll',device_code:'dev+1/=~ x&é*'}).toString()
            #expect(formBody(http.requests[1]) == "action=poll&device_code=dev%2B1%2F%3D%7E+x%26%C3%A9*")
        }

        @Test func pendingThenSuccessReportsPollingAndHonoursTheInterval() async throws {
            let http = RegistrationHTTP([
                .response(fakeBegin(interval: 3)),
                .response(json(["error": "authorization_pending"])),
                .response(json(["error": "authorization_pending"], status: 400)),  // RFC 8628 uses HTTP 400
                .response(json(["client_id": "cli_1", "client_secret": "s_1"])),
            ])
            let statuses = Recorder<StatusChangeInfo>()
            let delays = Recorder<Double>()
            let qr = Recorder<QRCodeInfo>()
            let result = try await AppRegistration.register(
                options(http, onStatusChange: { statuses.append($0) }, onQRCodeReady: { qr.append($0) }),
                timers: testTimers(delays: delays))
            #expect(result.clientId == "cli_1")
            #expect(result.clientSecret == "s_1")
            #expect(result.userInfo == nil)
            #expect(statuses.values == [.init(status: .polling, interval: nil), .init(status: .polling, interval: nil)])
            #expect(delays.values == [3000, 3000])  // the first poll is immediate
            #expect(qr.values == [QRCodeInfo(url: "https://accounts.feishu.cn/page/launcher?from=sdk&source=node-sdk&tp=sdk", expireIn: 600)])
        }

        @Test func slowDownAddsFiveSecondsEachTime() async throws {
            let http = RegistrationHTTP([
                .response(fakeBegin()),
                .response(json(["error": "slow_down"], status: 400)),
                .response(json(["error": "slow_down"], status: 400)),
                .response(json(["error": "authorization_pending"], status: 400)),
                .response(json(["client_id": "cli_1", "client_secret": "s_1"])),
            ])
            let statuses = Recorder<StatusChangeInfo>()
            let delays = Recorder<Double>()
            _ = try await AppRegistration.register(options(http, onStatusChange: { statuses.append($0) }), timers: testTimers(delays: delays))
            #expect(statuses.values == [
                .init(status: .slowDown, interval: 10), .init(status: .slowDown, interval: 15), .init(status: .polling, interval: nil),
            ])
            #expect(delays.values == [10_000, 15_000, 15_000])
        }

        @Test func defaultsIntervalAndExpiryWhenBeginOmitsThem() async throws {
            let begin: JSONValue = ["device_code": "d", "verification_uri_complete": "https://accounts.feishu.cn/page/launcher"]
            let http = RegistrationHTTP([.response(json(begin)), .response(json(["error": "authorization_pending"])), .response(json(["error": "access_denied"]))])
            let delays = Recorder<Double>()
            let expiries = Recorder<Double>()
            let qr = Recorder<QRCodeInfo>()
            await #expect(throws: RegisterAppError.self) {
                try await AppRegistration.register(
                    options(http, onQRCodeReady: { qr.append($0) }),
                    timers: testTimers(delays: delays, expiry: { ms in expiries.append(ms); try await Task.sleep(for: .seconds(3600)) }))
            }
            #expect(delays.values == [5000])
            #expect(expiries.values == [600_000])
            #expect(qr.values.first?.expireIn == 600)
        }

        @Test func switchesToTheLarkDomainOnceAndPollsImmediately() async throws {
            let http = RegistrationHTTP([
                .response(fakeBegin()),
                // Credentials on the first brand detection are dropped: node re-polls on the Lark domain.
                .response(json(["client_id": "ignored", "client_secret": "ignored", "user_info": ["tenant_brand": "lark"]])),
                .response(json(["error": "authorization_pending", "user_info": ["tenant_brand": "lark"]])),
                .response(json(["client_id": "cli_l", "client_secret": "s_l", "user_info": ["open_id": "ou_l", "tenant_brand": "lark"]])),
            ])
            let statuses = Recorder<StatusChangeInfo>()
            let delays = Recorder<Double>()
            let result = try await AppRegistration.register(
                options(http, domain: "accounts.example.cn", larkDomain: "accounts.example.com", onStatusChange: { statuses.append($0) }),
                timers: testTimers(delays: delays))
            #expect(result == RegisterAppResult(clientId: "cli_l", clientSecret: "s_l", userInfo: .init(openId: "ou_l", tenantBrand: "lark")))
            #expect(statuses.values == [.init(status: .domainSwitched, interval: nil), .init(status: .polling, interval: nil)])
            #expect(delays.values == [5000])
            #expect(http.requests.map(\.url.host) == ["accounts.example.cn", "accounts.example.cn", "accounts.example.com", "accounts.example.com"])
        }

        @Test func defaultLarkDomain() async throws {
            let http = RegistrationHTTP([
                .response(fakeBegin()),
                .response(json(["user_info": ["tenant_brand": "lark"]])),
                .response(json(["client_id": "c", "client_secret": "s"])),
            ])
            _ = try await AppRegistration.register(options(http), timers: testTimers())
            #expect(http.requests.last?.url.absoluteString == "https://accounts.larksuite.com/oauth/v1/app/registration")
        }

        @Test func accessDeniedFailsWithTheServerDescription() async {
            let http = RegistrationHTTP([.response(fakeBegin()), .response(json(["error": "access_denied", "error_description": "user denied"], status: 400))])
            await #expect(throws: RegisterAppError(code: .accessDenied, description: "user denied")) {
                try await AppRegistration.register(options(http), timers: testTimers())
            }
        }

        @Test func expiredTokenWithoutDescriptionUsesUnknownError() async {
            let http = RegistrationHTTP([.response(fakeBegin()), .response(json(["error": "expired_token"], status: 400))])
            await #expect(throws: RegisterAppError(code: .expiredToken, description: "Unknown error")) {
                try await AppRegistration.register(options(http), timers: testTimers())
            }
        }

        @Test func anyOtherServerErrorIsTerminalAndKeepsItsCode() async {
            let http = RegistrationHTTP([.response(fakeBegin()), .response(json(["error": "invalid_grant", "error_description": "bad device code"], status: 400))])
            await #expect(throws: RegisterAppError(code: "invalid_grant", description: "bad device code")) {
                try await AppRegistration.register(options(http), timers: testTimers())
            }
        }

        @Test func responsesWithoutErrorOrCredentialsKeepPolling() async throws {
            let http = RegistrationHTTP([
                .response(fakeBegin()),
                .response(json([:])),
                .response(json(["error": ""])),
                .response(json(["client_id": "c", "client_secret": ""])),
                .response(LarkHTTPResponse(statusCode: 200, headers: [:], body: Data("not json".utf8))),
                .response(json(["client_id": "c", "client_secret": "s"])),
            ])
            let statuses = Recorder<StatusChangeInfo>()
            let delays = Recorder<Double>()
            let result = try await AppRegistration.register(options(http, onStatusChange: { statuses.append($0) }), timers: testTimers(delays: delays))
            #expect(result.clientId == "c")
            #expect(statuses.values.isEmpty)
            #expect(delays.values.count == 4)
        }

        @Test func expiryTimerFailsWithPollingTimedOut() async {
            let http = RegistrationHTTP([.response(fakeBegin(expiresIn: 2))], fallback: { _ in json(["error": "authorization_pending"]) })
            let expiries = Recorder<Double>()
            let timers = AppRegistration.Timers(
                pollDelay: { _ in try await Task.sleep(for: .milliseconds(5)) },
                expiry: { ms in expiries.append(ms); try await Task.sleep(for: .milliseconds(20)) })
            await #expect(throws: RegisterAppError(code: .expiredToken, description: "Polling timed out")) {
                try await AppRegistration.register(options(http), timers: timers)
            }
            #expect(expiries.values == [2000])
            try? await Task.sleep(for: .milliseconds(10))
            let count = http.requests.count
            try? await Task.sleep(for: .milliseconds(30))
            #expect(http.requests.count == count)  // polling stopped
        }

        @Test func expiryWinsOverAnInFlightPoll() async throws {
            let gate = Gate()
            let http = RegistrationHTTP([.response(fakeBegin()), .gate(gate)])
            let statuses = Recorder<StatusChangeInfo>()
            // The expiry fires while the first poll is still waiting for its response.
            let timers = AppRegistration.Timers(pollDelay: { _ in }, expiry: { _ in await waitUntil { http.requests.count == 2 } })
            await #expect(throws: RegisterAppError(code: .expiredToken, description: "Polling timed out")) {
                try await AppRegistration.register(options(http, onStatusChange: { statuses.append($0) }), timers: timers)
            }
            gate.open(json(["error": "authorization_pending"]))
            try await Task.sleep(for: .milliseconds(20))
            #expect(statuses.values.isEmpty)
            #expect(http.requests.count == 2)
        }

        @Test func transportErrorDuringPollingFails() async {
            let http = RegistrationHTTP([.response(fakeBegin()), .failure(URLError(.notConnectedToInternet))])
            await #expect {
                try await AppRegistration.register(options(http), timers: testTimers())
            } throws: { error in
                if case LarkError.transport = error { return true }
                return false
            }
        }

        @Test func httpErrorWithoutBodyFails() async {
            let http = RegistrationHTTP([.response(fakeBegin()), .response(LarkHTTPResponse(statusCode: 502, headers: [:], body: Data()))])
            await #expect {
                try await AppRegistration.register(options(http), timers: testTimers())
            } throws: { error in
                if case LarkError.http(502, _, _) = error { return true }
                return false
            }
        }

        @Test func beginFailuresPropagate() async {
            let failing = RegistrationHTTP([.response(LarkHTTPResponse(statusCode: 500, headers: [:], body: Data()))])
            await #expect {
                try await AppRegistration.register(options(failing), timers: testTimers())
            } throws: { error in
                if case LarkError.http(500, _, _) = error { return true }
                return false
            }
            let invalid = RegistrationHTTP([.response(json(["device_code": "d", "verification_uri_complete": "not a url"]))])
            await #expect {
                try await AppRegistration.register(options(invalid), timers: testTimers())
            } throws: { error in
                if case LarkError.decoding = error { return true }
                return false
            }
            let missing = RegistrationHTTP([.response(json(["error": "invalid_client"], status: 400))])
            await #expect {
                try await AppRegistration.register(options(missing), timers: testTimers())
            } throws: { error in
                if case LarkError.decoding = error { return true }
                return false
            }
        }

        @Test func customDomainIsUsedForBeginAndPoll() async throws {
            let http = RegistrationHTTP([.response(fakeBegin()), .response(json(["client_id": "c", "client_secret": "s"]))])
            _ = try await AppRegistration.register(options(http, domain: "accounts.example.cn:8443"), timers: testTimers())
            #expect(http.requests.map(\.url.absoluteString) == Array(repeating: "https://accounts.example.cn:8443/oauth/v1/app/registration", count: 2))
        }

        @Test func publicEntryPointUsesTheGivenTransport() async throws {
            let http = RegistrationHTTP([.response(fakeBegin()), .response(json(["client_id": "c", "client_secret": "s"]))])
            let result = try await registerApp(options(http))
            #expect(result.clientId == "c")
        }

        @Test func liveTimersFollowSetTimeoutDelaySemantics() {
            #expect(AppRegistration.Timers.jsDelay(5000) == 5000)
            #expect(AppRegistration.Timers.jsDelay(0) == 1)
            #expect(AppRegistration.Timers.jsDelay(-3) == 1)
            #expect(AppRegistration.Timers.jsDelay(.nan) == 1)
            #expect(AppRegistration.Timers.jsDelay(2_147_483_648) == 1)
            #expect(AppRegistration.Timers.jsDelay(2_147_483_647) == 2_147_483_647)
        }
    }

    // MARK: - QR-code URL (node vectors)

    @Suite struct RegisterAppQRCodeURLTests {
        // Produced by replaying the URL steps of node-sdk scene/registration/index.ts with Node's own
        // WHATWG `URL` / `URLSearchParams` and node-sdk's `encodeAddons` (Node 26, macOS).
        @Test func matchesNodeForTheDefaultLink() throws {
            let o = options(RegistrationHTTP([]))
            #expect(try AppRegistration.buildQRCodeURL("https://accounts.feishu.cn/page/launcher", options: o)
                == "https://accounts.feishu.cn/page/launcher?from=sdk&source=node-sdk&tp=sdk")
        }

        @Test func matchesNodeWithEveryOptionAndAnExistingQuery() throws {
            let o = options(
                RegistrationHTTP([]),
                source: "lark cli~1",
                appPreset: AppPreset(
                    avatar: ["https://example.com/a.png?x=1&y=2", "https://example.com/b c.png"], name: "{user}的应用",
                    desc: "a+b=c & d/e*f~g'h!"),
                addons: AppAddons(scopes: .init(tenant: ["im:message:send_as_bot"])),
                appId: "cli_a1b2c3",
                createOnly: true)
            let url = try AppRegistration.buildQRCodeURL(
                "https://accounts.feishu.cn/oauth/v1/device/verify?flow_id=F%2B1&user_code=AB%20CD&from=web&tp=x#frag", options: o)
            var expected = "https://accounts.feishu.cn/oauth/v1/device/verify?flow_id=F%2B1&user_code=AB+CD&from=sdk&tp=sdk"
            expected += "&source=node-sdk%2Flark+cli%7E1&avatar=https%3A%2F%2Fexample.com%2Fa.png%3Fx%3D1%26y%3D2"
            expected += "&avatar=https%3A%2F%2Fexample.com%2Fb+c.png&name=%7Buser%7D%E7%9A%84%E5%BA%94%E7%94%A8"
            expected += "&desc=a%2Bb%3Dc+%26+d%2Fe*f%7Eg%27h%21"
            expected += "&addons=H4sIAAAAAAAAE6tWKk7OL0gtVrKqVipJzUvMK1GyilbKzLXKTS0uTkxPtSpOzUuJTyyOT8ovUYqtrQUAgA4mvDAAAAA"
            expected += "&createOnly=true&clientID=cli_a1b2c3#frag"
            if Gzip.osCode == 19 {
                #expect(url == expected)
            } else {
                let addons = "&addons=H4sIAAAAAAAAE6tWKk7OL0gtVrKqVipJzUvMK1GyilbKzLXKTS0uTkxPtSpOzUuJTyyOT8ovUYqtrQUAgA4mvDAAAAA"
                #expect(url.replacingOccurrences(of: #"&addons=[^&]*"#, with: "", options: .regularExpression)
                    == expected.replacingOccurrences(of: addons, with: ""))
            }
        }

        @Test func matchesNodeForABareHostAndAnEmptySource() throws {
            let o = options(RegistrationHTTP([]), source: "")
            #expect(try AppRegistration.buildQRCodeURL("https://accounts.feishu.cn", options: o)
                == "https://accounts.feishu.cn/?from=sdk&source=node-sdk&tp=sdk")
        }

        @Test func searchParamsSetReplacesTheFirstAndDropsTheRest() {
            var q = FormURLEncoded(parsing: "a=1&b=2&a=3&c&&a=4")
            q.set("a", "x")
            #expect(q.serialized() == "a=x&b=2&c=")
            q.set("d", "y z")
            #expect(q.serialized() == "a=x&b=2&c=&d=y+z")
            #expect(FormURLEncoded(parsing: "k=%zz%41+%E4%B8%AD").get("k") == "%zzA 中")
        }
    }

    // MARK: - encodeAddons (node: scene/registration/__tests__/addons.ts)

    @Suite struct EncodeAddonsTests {
        @Test(.enabled(if: hasZlib)) func roundTripsAFullAddonsObjectThroughThePlatformDecodeChain() throws {
            #expect(try decodeAddons(try AddonsEncoder.encode(fullAddons)) == fullAddons.jsonValue)
        }

        @Test func outputOnlyContainsURLSafeCharactersAndNoPadding() throws {
            // Large payload to make raw base64 '+' / '/' / '=' likely
            let addons = AppAddons(scopes: .init(tenant: (0..<100).map { "scope:item_\($0):readonly" }))
            let encoded = try AddonsEncoder.encode(addons)
            #expect(!encoded.isEmpty)
            #expect(encoded.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        }

        @Test(.enabled(if: hasZlib)) func keepsOnlyTheSectionsThatWereProvided() throws {
            let encoded = try AddonsEncoder.encode(AppAddons(scopes: .init(tenant: ["im:message:send_as_bot"])))
            #expect(try decodeAddons(encoded) == ["scopes": ["tenant": ["im:message:send_as_bot"]]])
        }

        @Test func throwsOnUnknownTopLevelKeys() {
            let addons: JSONValue = ["scopes": ["tenant": ["im:message:send_as_bot"]], "security": ["allowed_ips": ["1.2.3.4"]]]
            #expect(addonsErrorMessage(addons) == "addons.security is not allowed; allowed keys: preset, scopes, events, callbacks")
        }

        @Test func throwsOnTypoedTopLevelKeysInsteadOfSilentlyDroppingThem() {
            #expect(addonsErrorMessage(["scope": ["tenant": ["im:message:send_as_bot"]]])
                == "addons.scope is not allowed; allowed keys: preset, scopes, events, callbacks")
        }

        @Test func throwsOnUnknownNestedKeys() {
            #expect(addonsErrorMessage(["scopes": ["tenant": [], "bot": ["x"]]]) == "addons.scopes.bot is not allowed; allowed keys: tenant, user")
            #expect(addonsErrorMessage(["events": ["items": ["app": ["x"]]]]) == "addons.events.items.app is not allowed; allowed keys: tenant, user")
        }

        @Test func throwsWhenASectionIsNotAnObject() {
            #expect(addonsErrorMessage(["scopes": ["x"]]) == "addons.scopes must be an object")
        }

        @Test func throwsWhenALeafFieldIsNotAnArray() {
            #expect(addonsErrorMessage(["scopes": ["tenant": "im:message:send_as_bot"]]) == "addons.scopes.tenant must be an array of strings")
        }

        @Test func throwsOnEmptyStringItemsIncludingTheItemIndex() {
            #expect(addonsErrorMessage(AppAddons(callbacks: .init(items: ["card.action.trigger", ""])))
                == "addons.callbacks.items[1] must be a non-empty string")
        }

        @Test func throwsOnNonStringItems() {
            #expect(addonsErrorMessage(["scopes": ["user": [42]]]) == "addons.scopes.user[0] must be a non-empty string")
        }

        @Test func throwsWhenEveryListIsEmptyOrMissing() {
            let message = "addons must contain at least one scope, event or callback"
            #expect(addonsErrorMessage(AppAddons()) == message)
            #expect(addonsErrorMessage(AppAddons(scopes: .init(tenant: [], user: []))) == message)
            #expect(addonsErrorMessage(AppAddons(events: .init())) == message)
            #expect(addonsErrorMessage(AppAddons(events: .init(items: .init()), callbacks: .init(items: []))) == message)
        }

        @Test func throwsWhenAddonsItselfIsNotAnObject() {
            #expect(addonsErrorMessage(JSONValue.string("x")) == "addons must be an object")
            #expect(addonsErrorMessage(JSONValue.array([])) == "addons must be an object")
        }

        @Test(.enabled(if: hasZlib)) func passesPresetTrueThroughAlongsideTheDeclaredSections() throws {
            let addons = AppAddons(preset: true, scopes: .init(tenant: ["im:message:send_as_bot"]))
            #expect(try decodeAddons(try AddonsEncoder.encode(addons)) == ["preset": true, "scopes": ["tenant": ["im:message:send_as_bot"]]])
        }

        @Test(.enabled(if: hasZlib)) func passesPresetFalseThroughAlongsideTheDeclaredSections() throws {
            let addons = AppAddons(preset: false, scopes: .init(tenant: ["im:message:send_as_bot"]))
            #expect(try decodeAddons(try AddonsEncoder.encode(addons)) == ["preset": false, "scopes": ["tenant": ["im:message:send_as_bot"]]])
        }

        @Test(.enabled(if: hasZlib)) func allowsPresetFalseWithZeroAddonSections() throws {
            #expect(try decodeAddons(try AddonsEncoder.encode(AppAddons(preset: false))) == ["preset": false])
        }

        @Test func throwsOnPresetTrueWithZeroAddonSections() {
            #expect(addonsErrorMessage(AppAddons(preset: true)) == "addons must contain at least one scope, event or callback")
        }

        @Test func stillRequiresAtLeastOneSectionWhenPresetIsAbsent() {
            let message = "addons must contain at least one scope, event or callback"
            #expect(addonsErrorMessage(AppAddons()) == message)
            #expect(addonsErrorMessage(AppAddons(scopes: .init())) == message)
        }

        @Test(.enabled(if: hasZlib)) func doesNotInjectAPresetKeyWhenPresetIsNotProvided() throws {
            let decoded = try decodeAddons(try AddonsEncoder.encode(AppAddons(scopes: .init(tenant: ["x"]))))
            #expect(decoded["preset"] == nil)
        }

        @Test func throwsOnNonBooleanPresetValidatedBeforeTheEmptyPayloadCheck() {
            #expect(addonsErrorMessage(["preset": "false"]) == "addons.preset must be a boolean")
            #expect(addonsErrorMessage(["preset": 0]) == "addons.preset must be a boolean")
            #expect(addonsErrorMessage(["preset": nil]) == "addons.preset must be a boolean")
        }
    }

    // MARK: - encodeAddons node vectors

    @Suite struct EncodeAddonsVectorTests {
        // Produced by running node-sdk's own scene/registration/addons.ts (`encodeAddons`, with the
        // `AppAddons` import changed to `import type` so Node 26 can strip the types) on macOS:
        //   node gen.mts   →   { encoded, json: gunzip(encoded) }
        // Node's gzip header carries zlib's OS code (19 on macOS, 3 on Linux); the comparison patches
        // that one byte to this platform's code, everything else must be identical.
        static let vectors: [(name: String, addons: JSONValue, encoded: String, json: String)] = [
            (
                "full",
                fullAddons.jsonValue,
                "H4sIAAAAAAAAE22NwQrDIBBE_2XPQSj05K-UIBsdrDRq0a1QQv-9RkootJdlYGfe26jafEclvZEgcRLSFwpRR9TKHroiOcPVLFloIldCgx5XRQg7FtYF7HJanzRP9KgoO8Hy2odc9BH2Fs2vidCQZAiDIP6Y1cesCiy6x7TTP7A6wuApe-Xk4Uw7d0m39Pe6sL19i_Z1cYqthJyUlOB9h_b6GwOF2-MGAQAA",
                #"{"scopes":{"tenant":["im:message:send_as_bot","drive:drive.metadata:readonly"],"user":["calendar:calendar:read"]},"events":{"items":{"tenant":["im.message.receive_v1"],"user":["calendar.calendar.event.changed_v4"]}},"callbacks":{"items":["card.action.trigger"]}}"#
            ),
            (
                "tenantOnly",
                ["scopes": ["tenant": ["im:message:send_as_bot"]]],
                "H4sIAAAAAAAAE6tWKk7OL0gtVrKqVipJzUvMK1GyilbKzLXKTS0uTkxPtSpOzUuJTyyOT8ovUYqtrQUAgA4mvDAAAAA",
                #"{"scopes":{"tenant":["im:message:send_as_bot"]}}"#
            ),
            (
                "large",
                ["scopes": ["tenant": .array((0..<100).map { .string("scope:item_\($0):readonly") })]],
                "H4sIAAAAAAAAE3XWu04DMRBA0X_ZmgI_xo_9FYSiCLZAgg0i26Ao_05Bk-a0tzuyPePbcn27fG_XZb0tx7af92NZX_7b-nFsX6fn9Wc7v1_2z9_l6bEn9Ixe0Ct6oDf0jj7Qp1wES5xETjInoZPUSewkdxI8SZ4lzzxrybPkWfIseZY8S54lz5IXyYvkhddc8iJ5kbxIXiQvkhfJq-RV8ip55QuXvEpeJa-SV8mr5CF5SB6Sh-TB4SZ5SB6Sh-QheZO8Sd4kb5I3yRvnuuRN8iZ5k7xL3iXvknfJu-Rd8s6VJnmXvEs-JB-SD8mH5EPyIfmQfHCbSz4kn5JPyafkU_Ip-ZR8Sj4ln_zIPMhf7_c_IXM0q9EJAAA",
                #"{"scopes":{"tenant":["# + (0..<100).map { "\"scope:item_\($0):readonly\"" }.joined(separator: ",") + "]}}"
            ),
            (
                "presetTrue",
                ["preset": true, "scopes": ["tenant": ["im:message:send_as_bot"]]],
                "H4sIAAAAAAAAEw3IuQ2AMBAEwF42poJrBSHrDCtE4EfeI7LcO0w4E31QDFiMlxt0tk7BJoLV6_87nmKFkt80sV7JlXILHGt9fZOVaD4AAAA",
                #"{"preset":true,"scopes":{"tenant":["im:message:send_as_bot"]}}"#
            ),
            (
                "presetFalse",
                ["preset": false, "scopes": ["tenant": ["im:message:send_as_bot"]]],
                "H4sIAAAAAAAAEw3JwQmAMBAEwF72bQXXiki46CqCuQQ3v5Dedb4z0F6KHXb6Iy7QXhsFG-gMjz9W3MUKJb9oYhzJlXLt2Ob8ADrDyYw_AAAA",
                #"{"preset":false,"scopes":{"tenant":["im:message:send_as_bot"]}}"#
            ),
            (
                "presetFalseOnly",
                ["preset": false],
                "H4sIAAAAAAAAE6tWKihKLU4tUbJKS8wpTq0FAC919OgQAAAA",
                #"{"preset":false}"#
            ),
            (
                "presetFalseEmptySections",
                ["preset": false, "scopes": [:], "events": [:], "callbacks": [:]],
                "H4sIAAAAAAAAE6tWKihKLU4tUbJKS8wpTtVRKk7OL0gtVrKqrtVRSk7MyUlKTM4Gc2sBiH5elisAAAA",
                #"{"preset":false,"scopes":{},"callbacks":{}}"#
            ),
            (
                "reordered",
                [
                    "callbacks": ["items": ["card.action.trigger"]], "events": ["items": ["user": ["u.e"], "tenant": ["t.e"]]],
                    "scopes": ["user": ["u:s"], "tenant": ["t:s"]], "preset": true,
                ],
                "H4sIAAAAAAAAE13LMQ6DMBBE0btMbfkAvgpK4ZgRskIM2l3TIO6edaqE8o_mndiFSkMy6QzQsu1UpBPGlpvvEywpHgFdKSP7yCuAB5t9r9X4vpvIPzPyclTyuj5zef26yVeZYy5WtxZN6rK48vsH_GHG7p0AAAA",
                #"{"preset":true,"scopes":{"tenant":["t:s"],"user":["u:s"]},"events":{"items":{"tenant":["t.e"],"user":["u.e"]}},"callbacks":{"items":["card.action.trigger"]}}"#
            ),
            (
                "escaping",
                ["scopes": ["tenant": ["quote\"back\\slash/solidus", "ctl\u{01}\u{1f}\n\t\u{08}\u{0c}\r", "中文🚀", "\u{2028}\u{2029}\u{7f}"]]],
                "H4sIAAAAAAAAE6tWKk7OL0gtVrKqVipJzUvMK1GyilYqLM0vSY1RSkpMzo6JKc5JLM7QL87PyUwpLVbSUUouyYkpNTAwMASRhmkxeTElMUkxaTFFQLknO9Y-m9b-Yf6sBiDnUcOKRw0r65Via2sBA_W79WcAAAA",
                #"{"scopes":{"tenant":["quote\"back\\slash/solidus","ctl\u0001\u001f\n\t\b\f\r","中文🚀","#
                    + "\"\u{2028}\u{2029}\u{7f}\"]}}"
            ),
            (
                "x",
                ["scopes": ["tenant": ["x"]]],
                "H4sIAAAAAAAAE6tWKk7OL0gtVrKqVipJzUvMK1GyilaqUIqtrQUAw0NhzxsAAAA",
                #"{"scopes":{"tenant":["x"]}}"#
            ),
        ]

        @Test func normalizedJSONIsByteIdenticalToNode() throws {
            for v in Self.vectors {
                let actual = try AddonsEncoder.normalizedJSON(v.addons)
                #expect(actual == v.json, "\(v.name)")
            }
        }

        @Test func encodedOutputIsByteIdenticalToNode() throws {
            // Without any zlib the stored-block fallback is used: valid gzip, but not node's bytes.
            if case .stored = Gzip.defaultBackend { return }
            for v in Self.vectors {
                var expected = Array(try #require(Data(base64Encoded: Self.padded(v.encoded))))
                expected[9] = Gzip.osCode
                let actual = try #require(Data(base64Encoded: Self.padded(try AddonsEncoder.encode(v.addons))))
                #expect(Array(actual) == expected, "\(v.name)")
                if Gzip.osCode == 19 { #expect(try AddonsEncoder.encode(v.addons) == v.encoded, "\(v.name)") }
            }
        }

        static func padded(_ base64url: String) -> String {
            var s = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while s.count % 4 != 0 { s += "=" }
            return s
        }

        @Test func typedAddonsEncodeLikeTheirJSONForm() throws {
            #expect(try AddonsEncoder.normalizedJSON(fullAddons.jsonValue) == Self.vectors[0].json)
            let presetFalseEmpty = AppAddons(preset: false, scopes: .init(), events: .init(), callbacks: .init())
            #expect(try AddonsEncoder.normalizedJSON(presetFalseEmpty.jsonValue) == #"{"preset":false,"scopes":{},"callbacks":{}}"#)
        }

        // Messages produced by node-sdk's encodeAddons for each input (same script as above).
        @Test func errorMessagesMatchNode() {
            let cases: [(JSONValue, String)] = [
                (["scopes": ["tenant": ["a"]], "security": ["allowed_ips": ["1.2.3.4"]]], "addons.security is not allowed; allowed keys: preset, scopes, events, callbacks"),
                (["scope": ["tenant": ["a"]]], "addons.scope is not allowed; allowed keys: preset, scopes, events, callbacks"),
                (["scopes": ["tenant": [], "bot": ["x"]]], "addons.scopes.bot is not allowed; allowed keys: tenant, user"),
                (["events": ["items": ["app": ["x"]]]], "addons.events.items.app is not allowed; allowed keys: tenant, user"),
                (["scopes": ["x"]], "addons.scopes must be an object"),
                (["scopes": ["tenant": "im:message:send_as_bot"]], "addons.scopes.tenant must be an array of strings"),
                (["callbacks": ["items": ["card.action.trigger", ""]]], "addons.callbacks.items[1] must be a non-empty string"),
                (["scopes": ["user": [42]]], "addons.scopes.user[0] must be a non-empty string"),
                ([:], "addons must contain at least one scope, event or callback"),
                ("x", "addons must be an object"),
                ([], "addons must be an object"),
                (["preset": "false"], "addons.preset must be a boolean"),
                (["preset": nil], "addons.preset must be a boolean"),
                (["preset": true], "addons must contain at least one scope, event or callback"),
                (["events": 1], "addons.events must be an object"),
                (["events": ["items": []]], "addons.events.items must be an object"),
                (["events": ["item": [:]]], "addons.events.item is not allowed; allowed keys: items"),
                (["callbacks": ["items": ["a"], "extra": 1]], "addons.callbacks.extra is not allowed; allowed keys: items"),
                (["callbacks": ["items": [:]]], "addons.callbacks.items must be an array of strings"),
                (nil, "addons must be an object"),
                (["a": 1, "b": 2], "addons.a is not allowed; allowed keys: preset, scopes, events, callbacks"),
            ]
            for (input, message) in cases {
                #expect(addonsErrorMessage(input) == message, "\(input)")
            }
        }
    }

    // MARK: - gzip

    @Suite struct GzipTests {
        @Test func crc32KnownAnswer() {
            #expect(Gzip.crc32(Array("123456789".utf8)) == 0xCBF4_3926)
            #expect(Gzip.crc32([]) == 0)
        }

        @Test func dynamicallyLoadedZlibMatchesTheDefaultBackend() throws {
            #if canImport(Darwin)
            let lib = try #require(DynamicZlib.load(paths: ["/usr/lib/libz.1.dylib", "libz.dylib"]))
            #elseif canImport(Glibc)
            let lib = try #require(DynamicZlib.load(paths: ["libz.so.1", "libz.so"]))
            #else
            return
            #endif
            let payload = Array(EncodeAddonsVectorTests.vectors[2].json.utf8)
            #expect(Gzip.compress(payload, backend: .dynamic(lib)) == Gzip.compress(payload))
            #expect(DynamicZlib.load(paths: ["/nonexistent/libz.so"]).map { _ in true } == nil)
        }

        @Test(.enabled(if: hasZlib)) func storedFallbackIsValidGzip() throws {
            for size in [0, 1, 65_535, 65_536, 140_000] {
                let payload = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) }
                let stored = Gzip.compress(payload, backend: .stored)
                #expect(try gunzip(stored) == payload, "size \(size)")
            }
        }
    }
}
