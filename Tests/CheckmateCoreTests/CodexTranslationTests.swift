import XCTest
import Darwin
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform
import CodexAuth
import RealtimeConnection


/// A fake sign-in as Codex hands one out: a JWT naming a ChatGPT account, expiring in 2100.
let fakeTranslationToken = "eyJhbGciOiJub25lIn0.eyJleHAiOjQxMDI0NDQ4MDAsImh0dHBzOi8vYXBpLm9wZW5haS5jb20vYXV0aCI6eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0LWZpeHR1cmUifX0.c2ln"

final class CodexTranslationTests: XCTestCase {
    private final class Fixture {
        let directory: URL, executable: URL, marker: URL
        init(_ scenario: String) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            executable = directory.appendingPathComponent("fake-app-server")
            marker = directory.appendingPathComponent("marker.json")
            let script = """
            #!/usr/bin/python3
            import os, sys, json, pathlib, time
            scenario = '\(scenario)'
            def fail(kind, error, traceback):
                (pathlib.Path(__file__).parent / 'failure.txt').write_text(kind.__name__ + ': ' + str(error))
            sys.excepthook = fail
            home = pathlib.Path(os.environ['CODEX_HOME'])
            marker = pathlib.Path(__file__).parent / 'marker.json'
            assert 'OPENAI_API_KEY' not in os.environ and 'CODEX_API_KEY' not in os.environ
            config = (home / 'config.toml').read_text()
            assert all(flag + ' = false' in config for flag in ['shell_tool', 'unified_exec', 'daemon_auto_start', 'hooks', 'apps', 'browser_use', 'computer_use', 'remote_plugin'])
            assert (home / 'auth.json').stat().st_mode & 0o777 == 0o600
            # Written from the token alone: no refresh token, so this Codex can never rotate the learner's sign-in.
            private_auth = json.loads((home / 'auth.json').read_text())
            token = '\(fakeTranslationToken)'
            assert sorted(private_auth) == ['auth_mode', 'last_refresh', 'tokens'] and private_auth['auth_mode'] == 'chatgpt'
            assert private_auth['tokens'] == {'id_token': token, 'access_token': token, 'refresh_token': '', 'account_id': 'acct-fixture'}
            assert private_auth['last_refresh']
            assert os.environ['HOME'] == str(home.parent)
            assert pathlib.Path.cwd().name == 'work'
            marker.write_text(json.dumps({'scratch':str(home.parent),'pid':os.getpid(),'isolated':True}))
            def emit(v):
                print(json.dumps(v), flush=True)
            def notify(method, **params):
                emit({'method':method,'params':params})
            def tokens(total):
                notify('thread/tokenUsage/updated',threadId='thread',turnId='turn',tokenUsage={'total':{'inputTokens':80,'outputTokens':40,'totalTokens':total,'cachedInputTokens':10,'reasoningOutputTokens':5}})
            for line in sys.stdin:
                request = json.loads(line)
                if 'method' not in request:
                    # The client's answer to a server request (an approval) this fake sent: always a refusal.
                    assert request.get('id') == 99 and 'error' in request and 'result' not in request, request
                    continue
                method = request['method']; params = request.get('params',{}); ident = request.get('id')
                if method == 'initialized': continue
                if scenario == 'timeout': time.sleep(10); continue
                result = {}
                if method == 'account/read': result = {'account':{'type':'apiKey' if scenario=='apiKey' else 'chatgpt','planType':'plus','email':'DO-NOT-EXPORT@example.invalid'}}
                if method == 'config/read':
                    config_text=(home/'config.toml').read_text()
                    config_lines=[line.strip() for line in config_text.splitlines()]
                    fs_index=config_lines.index('[permissions.checkmate-lessons.filesystem]')
                    net_index=config_lines.index('[permissions.checkmate-lessons.network]')
                    features_index=config_lines.index('[features]')
                    assert config_lines[fs_index+1:net_index]==['\"'+str(home.parent/'work')+'\" = \"read\"']
                    assert config_lines[net_index+1:features_index]==['enabled = false']
                    assert len([line for line in config_lines if line.startswith('[permissions.')])==2
                    feature_names=['shell_tool','unified_exec','daemon_auto_start','hooks','apps','browser_use','browser_use_external','computer_use','image_generation','remote_plugin','view_image','multi_agent']
                    assert config_lines[features_index+1:]==[name+' = false' for name in feature_names]
                    assert 'default_permissions = \"checkmate-lessons\"' in config_text
                    assert 'sandbox_mode' not in config_text
                    assert 'project_doc_max_bytes = 0' in config_text
                    config={'approval_policy':'never','web_search':'disabled','default_permissions':'checkmate-lessons','project_doc_max_bytes':0,'permissions':{'checkmate-lessons':{'filesystem':{str(home.parent/'work'):'read'},'network':{'enabled':False}}}}
                    config['features']={name:False for name in feature_names}
                    assert 'sandbox_mode' not in config
                    assert config['default_permissions']=='checkmate-lessons'
                    profile=config['permissions']['checkmate-lessons']
                    assert profile['filesystem']=={str(home.parent/'work'):'read'}
                    assert profile['network']['enabled'] is False
                    if scenario=='unsafeReads': profile['filesystem'][':root']='read'
                    if scenario=='unsafeParent': profile['extends']=':read-only'
                    if scenario=='unsafeNetwork': profile['network']['enabled']=True
                    if scenario=='unsafeConfig': config['sandbox_mode']='workspace-write'
                    if scenario=='unsafeFeature': config['features']['shell_tool']=True
                    if scenario=='unsafeProfileKey': profile['unknown_grant']=True
                    if scenario=='unsafeNetworkKey': profile['network']['domains']={'example.invalid':'allow'}
                    if scenario=='unsafeExtraProfile': config['permissions']['other']={}
                    if scenario=='unsafeWorkspaceRoots': profile['workspace_roots']=['/']
                    if scenario=='unsafeSelection': config['default_permissions']=':read-only'
                    if scenario=='unsafeApproval': config['approval_policy']='on-request'
                    if scenario=='unsafeSearch': config['web_search']='enabled'
                    if scenario=='unsafeProjectDocs': config['project_doc_max_bytes']=32768
                    if scenario=='unsafeWrite': profile['filesystem'][str(home.parent/'work')]='write'
                    result={'config':config}
                if method == 'mcpServerStatus/list': result = {'data':[{'name':'unexpected-fixture-server'}] if scenario=='inheritedMCP' else [], 'nextCursor':None}
                if method == 'thread/start':
                    assert os.path.realpath(params['cwd']) == str(pathlib.Path.cwd()), 'cwd mismatch: '+params['cwd']+' / '+str(pathlib.Path.cwd())
                    assert params['ephemeral'] and 'sandbox' not in params
                    result = {'thread':{'id':'thread'},'model':'fake-translation-model','activePermissionProfile':{'id':':read-only' if scenario=='unsafeThreadProfile' else 'checkmate-lessons','extends':None},'sandbox':{'type':'readOnly','networkAccess':scenario=='unsafeThreadNetwork'}}
                    if scenario=='unsafeThreadExtra': result['sandbox']['access']={'type':'fullAccess'}
                if method == 'turn/start':
                    assert 'sandboxPolicy' not in params
                    assert params['outputSchema']['additionalProperties'] is False
                    emit({'id':ident,'result':{'turn':{'id':'turn','status':'inProgress'}}})
                    if scenario == 'tool':
                        emit({'id':99,'method':'item/commandExecution/requestApproval','params':{}}); continue
                    if scenario == 'cancel': time.sleep(10); continue
                    source = json.loads(params['input'][0]['text'].split('Untrusted lesson data:\\n',1)[1])
                    if scenario == 'fatal': notify('error',threadId='thread',turnId='turn',willRetry=False); continue
                    if scenario == 'unscopedFatal': notify('error',willRetry=False); continue
                    notify('item/completed',threadId='other',turnId='turn',item={'type':'agentMessage','text':'invalid unrelated output'})
                    notify('error',threadId='thread',turnId='other-turn',willRetry=False)
                    notify('error',threadId='thread',turnId='turn',willRetry=True)
                    if scenario != 'late': tokens(120); tokens(120); tokens(100)
                    notify('item/completed',threadId='thread',turnId='turn',item={'type':'agentMessage','phase':'final_answer','text':json.dumps(source)})
                    notify('turn/completed',threadId='other',turn={'id':'other-turn','status':'failed'})
                    notify('turn/completed',threadId='thread',turn={'id':'turn','status':'completed'})
                    if scenario == 'late': tokens(120)
                    continue
                if method == 'account/rateLimits/read':
                    result = {'rateLimits':{'primary':{'usedPercent':12,'resetsAt':2000000000},'credits':{'balance':'3.5'}}}
                if method == 'account/usage/read':
                    if scenario == 'estimateDisconnect': sys.exit(0)
                    if scenario == 'estimateTimeout':
                        (pathlib.Path(__file__).parent / 'estimate-started').touch()
                        time.sleep(10); continue
                    if scenario == 'estimateTool': emit({'id':99,'method':'item/commandExecution/requestApproval','params':{}}); continue
                    if scenario == 'unsupported': emit({'id':ident,'error':{'code':-32601,'message':'unsupported'}}); continue
                    if params.get('threadId'):
                        result = {'summary':{},'threadUsage':{'threadId':'thread','estimatedUsageCreditsMicros':1250000,'estimatedUsageUsdMicros':25000}}
                    else: result = {'summary':{'lifetimeTokens':4321}}
                emit({'id':ident,'result':result})
            """
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        // A liveness bound, not a speed check: a cold Rosetta launch of the fake server can take over a second. Tests of
        // the timeout itself pass their own short value.
        var client: CodexSubscriptionClient { client() }
        func client(timeout: TimeInterval = CodexTranslationLimits.rpcTimeout,
                    signIn: @escaping @Sendable () async throws -> Token = { Token(bearer: fakeTranslationToken, expires: nil) }) -> CodexSubscriptionClient {
            CodexSubscriptionClient(executable: executable, automationAllowed: true, timeout: timeout, cleanupObserver: nil, signIn: signIn)
        }
        func assertCleaned() async throws {
            let failure = directory.appendingPathComponent("failure.txt")
            if FileManager.default.fileExists(atPath: failure.path) { XCTFail(try String(contentsOf: failure, encoding: .utf8)) }
            guard FileManager.default.fileExists(atPath: marker.path) else { return }
            let markerData = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as! [String: Any]
            let scratch = markerData["scratch"] as! String, pid = Int32(markerData["pid"] as! Int)
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline && (FileManager.default.fileExists(atPath: scratch) || kill(pid, 0) == 0) { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: scratch), "Disposable credentials were not removed")
            XCTAssertNotEqual(kill(pid, 0), 0, "App-server child was not reaped")
        }
    }
    func testStructuredTranslationIsolatedRoutingAndCumulativeUsage() async throws {
        let fixture = try Fixture("normal"), source = LessonTranslation.source(library: try CourseLibrary(), index: 0)
        let result = try await fixture.client.translate(source: source, locale: "fr", onUsage: { _, _, _ in })
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.tokens?.total, 120)
        XCTAssertEqual(result.model, "fake-translation-model")
        XCTAssertEqual(result.estimatedCredits, 1.25)
        XCTAssertEqual(result.estimatedUSD, 0.025)
        try await fixture.assertCleaned()
    }
    /// Codex hands out the sign-in (renewing it), and the private home's sign-in is written from that token alone, so a
    /// keychain sign-in works as a file one does. A sign-in Codex cannot give names its own fix, and a token the private
    /// sign-in refuses stops before any child starts.
    func testPrivateSignInIsWrittenFromTheTokenCodexHandsOut() async throws {
        let source = LessonTranslation.source(library: try CourseLibrary(), index: 0)
        let handedOut = try Fixture("normal")
        let result = try await handedOut.client.translate(source: source, locale: "fr", onUsage: { _, _, _ in })
        XCTAssertEqual(result.text, source)
        try await handedOut.assertCleaned()
        let setup = CheckmateError.unavailable("Codex sign-in or private translation setup is unavailable.")
        func token(_ payload: String) -> @Sendable () async throws -> Token { { Token(bearer: "eyJhbGciOiJub25lIn0." + payload + ".c2ln", expires: nil) } }
        let cases: [(String, @Sendable () async throws -> Token, CheckmateError)] = [
            ("renewal failed", { throw CodexAuthError(.expired) }, CodexSubscriptionClient.signInFailure(.expired)),
            ("keychain unsupported", { throw CodexAuthError(.appServerAuthUnavailable) }, CodexSubscriptionClient.signInFailure(.appServerAuthUnavailable)),
            ("API key", { throw CodexAuthError(.apiKey, mode: "apikey") }, CodexSubscriptionClient.signInFailure(.apiKey)),
            ("not signed in", { throw CodexAuthError(.notSignedIn) }, CodexSubscriptionClient.signInFailure(.notSignedIn)),
            ("opaque token", { Token(bearer: "opaque-token", expires: nil) }, setup),
            ("no account", token("eyJleHAiOjQxMDI0NDQ4MDB9"), setup),
            ("expired token", token("eyJleHAiOjEsImh0dHBzOi8vYXBpLm9wZW5haS5jb20vYXV0aCI6eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2N0LWZpeHR1cmUifX0"), setup),
        ]
        for (name, signIn, expected) in cases {
            let fixture = try Fixture("normal")
            do { _ = try await fixture.client(signIn: signIn).translate(source: source, locale: "fr", onUsage: { _, _, _ in }); XCTFail(name) }
            catch {
                XCTAssertEqual(userFacingMessage(error, fallback: ""), userFacingMessage(expected, fallback: ""), name)
                XCTAssertFalse(String(describing: error).contains("opaque-token"), name)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path), "\(name): a child was started")
        }
        let cancelled = try Fixture("normal")
        do { _ = try await cancelled.client(signIn: { throw CancellationError() }).accountStatus(); XCTFail("cancelled") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        // The public initialiser gives automation no sign-in at all: a real account is never reached from a test.
        do { _ = try await CodexSubscriptionClient(executable: cancelled.executable, automationAllowed: true).accountStatus(); XCTFail("automation signed in") }
        catch { XCTAssertTrue(String(describing: error).contains("disabled during automation"), "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.marker.path))
    }
    func testLateUsageAndUnsupportedEstimates() async throws {
        for scenario in ["late", "unsupported", "estimateDisconnect", "estimateTimeout"] {
            let fixture = try Fixture(scenario), source = LessonTranslation.source(library: try CourseLibrary(), index: 0)
            // estimateTimeout waits out the estimate request, so it runs with a short request timeout of its own.
            let client = scenario == "estimateTimeout" ? fixture.client(timeout: 3) : fixture.client
            let result = try await client.translate(source: source, locale: "fr", onUsage: { _, _, _ in })
            XCTAssertEqual(result.tokens?.total, 120)
            if scenario != "late" { XCTAssertNil(result.estimatedCredits); XCTAssertNil(result.estimatedUSD) }
            try await fixture.assertCleaned()
        }
    }
    func testToolsAndAPIKeyAuthRejected() async throws {
        for scenario in ["tool", "estimateTool", "apiKey"] {
            let fixture = try Fixture(scenario), source = LessonTranslation.source(library: try CourseLibrary(), index: 0)
            do { _ = try await fixture.client.translate(source: source, locale: "fr", onUsage: { _, _, _ in }); XCTFail("Forbidden flow succeeded") }
            catch {
                let message = String(describing: error)
                XCTAssertFalse(message.contains(fakeTranslationToken))
                XCTAssertTrue(message.contains(scenario != "apiKey" ? "tool operation" : "ChatGPT"), message)
            }
            try await fixture.assertCleaned()
        }
    }
    func testTimeoutAndCancellationReapChildAndPrivateAuth() async throws {
        let fixture = try Fixture("timeout")
        let client = fixture.client(timeout: 0.2)
        do { _ = try await client.accountStatus(); XCTFail("Timeout succeeded") } catch { }
        try await fixture.assertCleaned()
        let cancelling = try Fixture("cancel"), source = LessonTranslation.source(library: try CourseLibrary(), index: 0)
        let task = Task { try await cancelling.client.translate(source: source, locale: "fr", onUsage: { _, _, _ in }) }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        try await cancelling.assertCleaned()
    }
    func testCancelAfterValidatedOutputIsFastAndPreservesResult() async throws {
        let fixture = try Fixture("estimateTimeout"), source = LessonTranslation.source(library: try CourseLibrary(), index: 0)
        let task = Task { try await fixture.client.translate(source: source, locale: "fr", onUsage: { _, _, _ in }) }
        let marker = fixture.directory.appendingPathComponent("estimate-started")
        for _ in 0..<200 { if FileManager.default.fileExists(atPath: marker.path) { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let start = Date(); task.cancel(); XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        let result = try await task.value
        XCTAssertEqual(result.text, source); XCTAssertEqual(result.tokens?.total, 120)
        try await fixture.assertCleaned()
    }
    func testAccountRefreshDoesNotRequireTranslationIsolationRPCs() async throws {
        let fixture = try Fixture("inheritedMCP")
        let status = try await fixture.client.accountStatus()
        XCTAssertTrue(status.contains("12% used"))
        try await fixture.assertCleaned()
    }
    func testEffectiveConfigAndInheritedMCPFailClosed() async throws {
        for scenario in ["unsafeConfig", "unsafeReads", "unsafeParent", "unsafeNetwork", "unsafeFeature", "unsafeProfileKey", "unsafeNetworkKey", "unsafeExtraProfile", "unsafeWorkspaceRoots", "unsafeSelection", "unsafeApproval", "unsafeSearch", "unsafeWrite", "unsafeThreadProfile", "unsafeThreadNetwork", "unsafeThreadExtra", "unsafeProjectDocs", "inheritedMCP"] {
            let fixture = try Fixture(scenario)
            do { _ = try await fixture.client.translate(source: LessonTranslation.source(library: try CourseLibrary(), index: 0), locale: "fr", onUsage: { _, _, _ in }); XCTFail("Unsafe isolation succeeded") }
            catch { XCTAssertTrue(String(describing: error).contains(scenario != "inheritedMCP" ? "private translation isolation" : "inherited an MCP")) }
            try await fixture.assertCleaned()
        }
    }
    func testFatalErrorsStopWithoutWaitingForTurnDeadline() async throws {
        for scenario in ["fatal", "unscopedFatal"] {
            let fixture = try Fixture(scenario), source = LessonTranslation.source(library: try CourseLibrary(), index: 0)
            do { _ = try await fixture.client.translate(source: source, locale: "fr", onUsage: { _, _, _ in }); XCTFail("Fatal error succeeded") }
            catch { XCTAssertTrue(String(describing: error).contains("could not complete")) }
            try await fixture.assertCleaned()
        }
    }
    func testAbandonedPrivateHomeIsRemovedAndActiveHomeKept() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        let abandoned = root.appendingPathComponent("checkmate-translation-" + UUID().uuidString)
        let active = root.appendingPathComponent("checkmate-translation-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: abandoned); try? FileManager.default.removeItem(at: active) }
        for entry in [abandoned, active] { try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        try Data("2147483647".utf8).write(to: abandoned.appendingPathComponent("owner.pid"))
        try Data(String(getpid()).utf8).write(to: active.appendingPathComponent("owner.pid"))
        let fixture = try Fixture("normal")
        _ = try await fixture.client.accountStatus()
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        try await fixture.assertCleaned()
    }
    func testAccountReportIncludesAccountWideLimitsWithoutIdentity() async throws {
        let fixture = try Fixture("normal")
        let status = try await fixture.client.accountStatus()
        XCTAssertTrue(status.contains("12% used")); XCTAssertTrue(status.contains("3.5")); XCTAssertTrue(status.contains("4321"))
        XCTAssertFalse(status.contains("DO-NOT-EXPORT")); XCTAssertFalse(status.contains("Provider thread estimate"))
        XCTAssertTrue(status.contains("Actual charges are not reported"))
        try await fixture.assertCleaned()
    }
}
