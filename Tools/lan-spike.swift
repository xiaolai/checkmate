// LAN-play spike (dev-docs/codex-plans/20261016-lan-play.md, build order 1). It proves the transport choices before
// any product code depends on them: TLS 1.2 ECDHE-PSK keyed through the D3 bootstrap (TXT record → game ID → HKDF),
// two listeners keeping roles apart, resumption off, loopback without the local-network prompt, and Bonjour across
// the test host and the LAN pair. Every probe writes a JSON verdict; nothing here is product code.
//
//   lan-spike serve   --dir D [--lan] [--service T]   two listeners; writes D/server.json, answers each connection
//                                                      with the role of the listener it arrived on
//   lan-spike connect --dir D --steps role:code,...   one process, steps in order; writes D/connect-<n>.json
//   lan-spike probe-a --dir D                          runs serve and connect as separate processes, judges (a)
//   lan-spike probe-b --dir D                          loopback only, no Bonjour; judges (b) from its own results
//   lan-spike browse  --dir D --service T [--game G]   Bonjour browse; records results or the -65570 denial
//   lan-spike join    --dir D --service T --code C     browse, pair by game ID, connect to the seat (spike c);
//                     [--game G]                       that game only; without it, exactly one game may be advertised
//                     [--retries N] [--attempt-timeout S]  fresh connections after a stall
import CoreGraphics
import CryptoKit
import Foundation
import Network

let arguments = CommandLine.arguments
func option(_ name: String) -> String? { arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
func flag(_ name: String) -> Bool { arguments.contains(name) }
/// Children started by `run`, stopped on every way out: `exit` skips `defer`, so cleanup cannot rely on it.
var children: [Process] = []
func quit(_ code: Int32) -> Never { for child in children where child.isRunning { child.terminate() }; exit(code) }
func fail(_ message: String) -> Never { FileHandle.standardError.write(Data((message + "\n").utf8)); quit(1) }
// The test host and the LAN pair carry ~/.config/checkmate/host-role naming "test" (alone or with "build"), the marker scripts/test_host.py reads.
let hostRoles=Set(((try? String(contentsOf:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/checkmate/host-role"),encoding:.utf8)) ?? "").split(whereSeparator:\.isWhitespace).map(String.init))
guard hostRoles.contains("test") else { fail("lan-spike runs on a test host or the LAN pair only.") }
guard arguments.count > 1, let directory = option("--dir").map({ URL(fileURLWithPath: $0) }) else {
    fail("Usage: lan-spike serve|connect|probe-a|probe-b|browse|join --dir <directory> [options]")
}
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let queue = DispatchQueue(label: "lan-spike")

func write(_ name: String, _ value: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { fail("Unencodable \(name)") }
    do { try data.write(to: directory.appendingPathComponent(name), options: .atomic) } catch { fail("Could not write \(name): \(error)") }
}
func read(_ name: String) -> [String: Any]? {
    (try? Data(contentsOf: directory.appendingPathComponent(name))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

// D3: Crockford base-32, no look-alikes. Game ID = 128 random bits as 26 symbols; codes = 8 symbols, 40 bits.
let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
func randomSymbols(_ count: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    return String((0..<count).map { _ in alphabet[Int(generator.next(upperBound: UInt32(alphabet.count)))] })
}
func gameID() -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { fail("No randomness") }
    var bits: [Int] = bytes.flatMap { byte -> [Int] in (0..<8).reversed().map { Int((byte >> UInt8($0)) & 1) } } + [0, 0]
    var text = ""
    while !bits.isEmpty { text.append(alphabet[bits.prefix(5).reduce(0) { $0 << 1 | $1 }]); bits.removeFirst(5) }
    return text
}
func psk(code: String, game: String, role: String) -> SymmetricKey {
    HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)), salt: Data(game.utf8),
                           info: Data("checkmate-lan v1 \(role)".utf8), outputByteCount: 32)
}

let pinnedSuite: UInt16 = 0xCCAC
func parameters(key: SymmetricKey, identity: String) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let security = tls.securityProtocolOptions
    let secret = key.withUnsafeBytes { DispatchData(bytes: $0) }
    let name = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(security, secret as __DispatchData, name as __DispatchData)
    sec_protocol_options_append_tls_ciphersuite(security, tls_ciphersuite_t(rawValue: pinnedSuite)!)
    sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)
    sec_protocol_options_set_tls_tickets_enabled(security, false)
    sec_protocol_options_set_tls_resumption_enabled(security, false)
    let tcp = NWProtocolTCP.Options()
    tcp.connectionTimeout = 5
    let result = NWParameters(tls: tls, tcp: tcp)
    result.includePeerToPeer = false
    return result
}
func negotiated(_ connection: NWConnection) -> (version: Int, suite: Int)? {
    guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return nil }
    let security = metadata.securityProtocolMetadata
    return (Int(sec_protocol_metadata_get_negotiated_tls_protocol_version(security).rawValue),
            Int(sec_protocol_metadata_get_negotiated_tls_ciphersuite(security).rawValue))
}
func hex(_ value: Int) -> String { String(format: "0x%04X", value) }

// MARK: serve

func serve() -> Never {
    let game = gameID(), lan = flag("--lan"), service = option("--service")
    let codes = ["seat": option("--seat-code") ?? randomSymbols(8), "watch": option("--watch-code") ?? randomSymbols(8)]
    var ports: [String: Int] = [:], txt: [String: String] = [:], accepted: [[String: Any]] = []
    var listeners: [NWListener] = []
    func publish() {
        guard ports.count == 2 else { return }
        write("server.json", ["game": game, "codes": codes, "ports": ports, "txt": txt, "pid": Int(getpid()), "lan": lan,
                              "service": service ?? NSNull(), "accepted": accepted])
    }
    for role in ["seat", "watch"] {
        let parameters = parameters(key: psk(code: codes[role]!, game: game, role: role), identity: game)
        if !lan { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
        let listener: NWListener
        do { listener = try NWListener(using: parameters) } catch { fail("Listener: \(error)") }
        let record = NWTXTRecord(["game": game, "role": role])
        txt[role] = record.data.base64EncodedString()
        if let service { listener.service = NWListener.Service(name: "Spike \(role) · \(game.suffix(4))", type: service, txtRecord: record) }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ports[role] = Int(listener.port?.rawValue ?? 0); publish()
            case .failed(let error), .waiting(let error): accepted.append(["listener": role, "listenerState": "\(error)"]); publish()
            default: break
            }
        }
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let tls = negotiated(connection)
                    accepted.append(["listener": role, "tlsVersion": tls.map { hex($0.version) } ?? "none",
                                     "cipherSuite": tls.map { hex($0.suite) } ?? "none", "remote": "\(connection.endpoint)"])
                    publish()
                    connection.send(content: Data(role.utf8), contentContext: .finalMessage, isComplete: true,
                                    completion: .contentProcessed { _ in queue.asyncAfter(deadline: .now() + 1) { connection.cancel() } })
                case .failed(let error):
                    accepted.append(["listener": role, "handshakeFailed": "\(error)"]); publish(); connection.cancel()
                default: break
                }
            }
            connection.start(queue: queue)
        }
        listener.start(queue: queue)
        listeners.append(listener)
    }
    signal(SIGTERM, SIG_IGN)
    let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
    terminate.setEventHandler { listeners.forEach { $0.cancel() }; quit(0) }
    terminate.resume()
    dispatchMain()
}

// MARK: connect

/// One TLS attempt. The role the server echoes is what the listener decided; the key decides whether we get that far.
func attempt(endpoint: NWEndpoint, key: SymmetricKey, identity: String, timeout: TimeInterval = 8) -> [String: Any] {
    let connection = NWConnection(to: endpoint, using: parameters(key: key, identity: identity))
    let done = DispatchSemaphore(value: 0)
    var result: [String: Any] = ["endpoint": "\(endpoint)"]
    var finished = false, history: [String] = []
    func finish(_ values: [String: Any]) {
        if finished { return }; finished = true; result.merge(values) { $1 }
        // A timeout alone says nothing; the states passed through and the last path say where it stuck.
        result["states"] = history; result["path"] = connection.currentPath.map { "\($0)" } ?? NSNull()
        connection.cancel(); done.signal()
    }
    connection.pathUpdateHandler = { path in history.append("path: \(path)") }
    connection.stateUpdateHandler = { state in
        history.append("\(state)")
        switch state {
        case .ready:
            let tls = negotiated(connection)
            result["tlsVersion"] = tls.map { hex($0.version) } ?? "none"
            result["cipherSuite"] = tls.map { hex($0.suite) } ?? "none"
            // The server writes its role and closes; one receive may return only part of it, so read to the end.
            var reply = Data()
            func readRole() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, isComplete, error in
                    if let data { reply.append(data) }
                    if isComplete || error != nil || data == nil || reply.count >= 64 {
                        finish(["state": "ready", "role": String(data: reply, encoding: .utf8) ?? "", "receiveError": error.map { "\($0)" } ?? NSNull()])
                    } else { readRole() }
                }
            }
            readRole()
        case .waiting(let error):
            if case .dns(let code) = error, code == -65570 { finish(["state": "denied", "error": "\(error)"]) }
            else if connection.currentPath?.unsatisfiedReason == .localNetworkDenied { finish(["state": "denied", "error": "\(error)"]) }
            else { finish(["state": "waiting", "error": "\(error)"]) }
        case .failed(let error): finish(["state": "failed", "error": "\(error)"])
        default: break
        }
    }
    connection.start(queue: queue)
    if done.wait(timeout: .now() + timeout) == .timedOut { queue.sync { finish(["state": "timeout"]) } }
    return queue.sync { result }
}

func connect() -> Never {
    guard let server = read("server.json"), let ports = server["ports"] as? [String: Int], let txt = server["txt"] as? [String: String],
          let steps = option("--steps")?.split(separator: ",") else { fail("connect needs server.json and --steps") }
    var results: [[String: Any]] = []
    for step in steps {
        let parts = step.split(separator: ":").map(String.init)
        guard parts.count == 3 else { fail("A step is listener:keyRole:code, not \(step)") }
        let (listener, keyRole, code) = (parts[0], parts[1], parts[2])
        // The joiner learns the game ID only from the TXT record it chose, never from anywhere else (D3).
        guard let data = txt[listener].flatMap({ Data(base64Encoded: $0) }), let game = NWTXTRecord(data)["game"],
              let port = ports[listener], let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { fail("No TXT for \(listener)") }
        var outcome = attempt(endpoint: .hostPort(host: "127.0.0.1", port: nwPort), key: psk(code: code, game: game, role: keyRole), identity: game)
        outcome["step"] = step
        results.append(outcome)
    }
    write(option("--out") ?? "connect.json", ["pid": Int(getpid()), "results": results])
    quit(0)
}

// MARK: probes

func run(_ extra: [String]) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    if !FileManager.default.isExecutableFile(atPath: process.executableURL!.path) { process.executableURL = Bundle.main.executableURL }
    process.arguments = extra + ["--dir", directory.path]
    do { try process.run() } catch { fail("Could not start \(extra): \(error)") }
    children.append(process)
    return process
}
func waitFor(_ name: String, timeout: TimeInterval = 15, _ ready: ([String: Any]) -> Bool) -> [String: Any] {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline { if let value = read(name), ready(value) { return value }; usleep(100_000) }
    fail("Timed out waiting for \(name)")
}

func probeA() -> Never {
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("server.json"))
    let server = run(["serve"] + (option("--seat-code").map { ["--seat-code", $0] } ?? []))
    let published = waitFor("server.json") { ($0["ports"] as? [String: Int])?.count == 2 }
    let codes = published["codes"] as! [String: String]
    let seat = codes["seat"]!, watch = codes["watch"]!, wrong = randomSymbols(8)
    // Separate processes: a right key on each listener. Then one process that has already completed a seat
    // handshake tries keys it must not be able to use, so a cached session could not stand in for the key.
    let cases: [(String, String)] = [
        ("connect-1.json", "seat:seat:\(seat),watch:watch:\(watch)"),
        ("connect-2.json", "seat:seat:\(seat),seat:seat:\(wrong),watch:watch:\(seat),watch:seat:\(seat),seat:watch:\(watch),watch:watch:\(watch)"),
    ]
    var steps: [[String: Any]] = []
    for (name, plan) in cases {
        let client = run(["connect", "--steps", plan, "--out", name])
        client.waitUntilExit()
        guard client.terminationStatus == 0, let value = read(name), let results = value["results"] as? [[String: Any]] else { fail("\(name) failed") }
        steps += results.map { $0.merging(["process": value["pid"] ?? 0, "file": name]) { a, _ in a } }
    }
    usleep(300_000)
    let finalServer = read("server.json") ?? [:]
    func step(_ file: String, _ index: Int) -> [String: Any] { steps.filter { $0["file"] as? String == file }[index] }
    func admitted(_ s: [String: Any], as role: String) -> Bool {
        s["state"] as? String == "ready" && s["role"] as? String == role && s["tlsVersion"] as? String == "0x0303" && s["cipherSuite"] as? String == hex(Int(pinnedSuite))
    }
    // Refused means the TLS handshake itself failed (Security's -98xx codes): a connection that reached ready, or one
    // that only timed out, proves nothing about the key.
    // The spike observed a wrong pre-shared key as -9820 at the client (and -9846 at the server); any other failure
    // is inconclusive, not a refusal.
    func refused(_ s: [String: Any]) -> Bool {
        let reachedReady = (s["states"] as? [String] ?? []).contains("ready"),error = s["error"] as? String ?? ""
        return !reachedReady && s["state"] as? String != "ready" && (error.contains("-9820") || error.contains("-9846"))
    }
    let checks: [String: Bool] = [
        "seatKeyOnSeatListener": admitted(step("connect-1.json", 0), as: "seat"),
        "watchKeyOnWatchListener": admitted(step("connect-1.json", 1), as: "watch"),
        "secondProcessSeat": admitted(step("connect-2.json", 0), as: "seat"),
        "wrongCodeRefusedAfterGoodSeat": refused(step("connect-2.json", 1)),
        "seatCodeWithWatchInfoRefusedOnWatch": refused(step("connect-2.json", 2)),
        "seatKeyRefusedOnWatchListener": refused(step("connect-2.json", 3)),
        "watchKeyRefusedOnSeatListener": refused(step("connect-2.json", 4)),
        "watchStillAdmitsRightKey": admitted(step("connect-2.json", 5), as: "watch"),
        "serverSawOnlyPinnedSuite": ((finalServer["accepted"] as? [[String: Any]]) ?? []).filter { $0["tlsVersion"] != nil }
            .allSatisfy { $0["tlsVersion"] as? String == "0x0303" && $0["cipherSuite"] as? String == hex(Int(pinnedSuite)) },
    ]
    let passed = checks.values.allSatisfy { $0 }
    write("probe-a.json", ["probe": "a", "passed": passed, "checks": checks, "steps": steps, "server": finalServer,
                           "macOS": ProcessInfo.processInfo.operatingSystemVersionString])
    print(passed ? "probe-a passed" : "probe-a FAILED")
    server.terminate()
    quit(passed ? 0 : 1)
}

func probeB() -> Never {
    // Loopback listeners and a loopback join, no Bonjour anywhere: none of it may wait on local-network permission.
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("server.json"))
    let server = run(["serve"])
    let published = waitFor("server.json") { ($0["ports"] as? [String: Int])?.count == 2 }
    let seat = (published["codes"] as! [String: String])["seat"]!
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("connect-b.json"))
    let client = run(["connect", "--steps", "seat:seat:\(seat)", "--out", "connect-b.json"])
    client.waitUntilExit()
    let result = (read("connect-b.json")?["results"] as? [[String: Any]])?.first ?? [:]
    let passed = client.terminationStatus == 0 && result["state"] as? String == "ready" && result["role"] as? String == "seat"
    write("probe-b.json", ["probe": "b", "passed": passed, "result": result, "macOS": ProcessInfo.processInfo.operatingSystemVersionString])
    print(passed ? "probe-b passed" : "probe-b FAILED")
    server.terminate()
    quit(passed ? 0 : 1)
}

// MARK: Bonjour

func browse(service: String, until stop: @escaping ([NWBrowser.Result]) -> Bool, timeout: TimeInterval) -> (state: String, results: [NWBrowser.Result]) {
    let parameters = NWParameters()
    parameters.includePeerToPeer = false
    let browser = NWBrowser(for: .bonjourWithTXTRecord(type: service, domain: nil), using: parameters)
    let done = DispatchSemaphore(value: 0)
    var state = "started", latest: [NWBrowser.Result] = [], finished = false
    func finish(_ value: String) { if finished { return }; finished = true; state = value; done.signal() }
    browser.stateUpdateHandler = { update in
        switch update {
        case .waiting(let error):
            if case .dns(let code) = error, code == -65570 { finish("denied(-65570)") } else { state = "waiting(\(error))" }
        case .failed(let error): finish("failed(\(error))")
        default: break
        }
    }
    browser.browseResultsChangedHandler = { results, _ in latest = Array(results); if stop(latest) { finish("results") } }
    browser.start(queue: queue)
    // At the deadline, results count only if they meet the caller's condition (the game it asked for, say).
    if done.wait(timeout: .now() + timeout) == .timedOut { queue.sync { finish(stop(latest) ? "results" : "timeout(\(state), \(latest.count) found)") } }
    browser.cancel()
    return queue.sync { (state, latest) }
}
func describe(_ result: NWBrowser.Result) -> [String: Any] {
    var txt: [String: String] = [:]
    if case .bonjour(let record) = result.metadata { txt = record.dictionary }
    return ["endpoint": "\(result.endpoint)", "txt": txt, "interfaces": result.interfaces.map { $0.name }]
}

func browseCommand() -> Never {
    let service = option("--service") ?? "_checkmate-auto._tcp", wanted = option("--game")
    let outcome = browse(service: service, until: { results in
        wanted.map { game in results.contains { if case .bonjour(let r) = $0.metadata { return r["game"] == game }; return false } } ?? !results.isEmpty
    }, timeout: Double(option("--timeout") ?? "20") ?? 20)
    let found = outcome.results.map(describe)
    let passed = outcome.state == "results" && !found.isEmpty
    write(option("--out") ?? "browse.json", ["service": service, "state": outcome.state, "results": found, "passed": passed,
                                              "macOS": ProcessInfo.processInfo.operatingSystemVersionString, "pid": Int(getpid())])
    print("browse \(outcome.state): \(found.count) result(s)")
    quit(passed ? 0 : 1)
}

func joinCommand() -> Never {
    // The joiner types only the code; game ID and endpoints come from the Bonjour records, paired by game ID.
    let service = option("--service") ?? "_checkmate-auto._tcp"
    guard let code = option("--code") else { fail("join needs --code") }
    let role = option("--role") ?? "seat",wanted = option("--game")
    let outcome = browse(service: service, until: { results in
        let games = results.compactMap { r -> (String, String)? in if case .bonjour(let t) = r.metadata, let g = t["game"], let role = t["role"], wanted == nil || g == wanted { return (g, role) }; return nil }
        return Dictionary(grouping: games, by: { $0.0 }).values.contains { Set($0.map { $0.1 }) == ["seat", "watch"] }
    }, timeout: Double(option("--timeout") ?? "20") ?? 20)
    var report: [String: Any] = ["service": service, "browse": outcome.state, "results": outcome.results.map(describe),
                                 "macOS": ProcessInfo.processInfo.operatingSystemVersionString]
    // A game counts only once both of its listeners are found; the role is taken from such a game, never from a stray.
    let complete = Dictionary(grouping: outcome.results.compactMap { r -> (String, String)? in if case .bonjour(let t) = r.metadata, let g = t["game"], let role = t["role"] { return (g, role) }; return nil }, by: { $0.0 }).filter { Set($0.value.map { $0.1 }) == ["seat", "watch"] && (wanted == nil || $0.key == wanted) }.keys
    // The code belongs to one game: with several advertised and none named, which one is a guess, so refuse.
    if wanted == nil, complete.count > 1 { report["error"] = "\(complete.count) games advertised; name one with --game"; write(option("--out") ?? "join.json", report); fail("join: several games advertised; name one with --game") }
    let chosen = outcome.results.first { if case .bonjour(let t) = $0.metadata, let game = t["game"] { return t["role"] == role && complete.contains(game) }; return false }
    if let chosen, case .bonjour(let record) = chosen.metadata, let game = record["game"] {
        let pair = outcome.results.filter { if case .bonjour(let t) = $0.metadata { return t["game"] == game }; return false }
        report["pairedByGame"] = pair.count
        // After an app's binary changes, macOS can refuse its first local connection while it refreshes the binary's
        // permission record, and Network.framework reports that only as a stall in preparing; --retries shows
        // whether a fresh attempt in the same process recovers.
        let retries = max(0, Int(option("--retries") ?? "0") ?? 0), perAttempt = Double(option("--attempt-timeout") ?? "10") ?? 10
        var attempts: [[String: Any]] = []
        var connected: [String: Any] = [:]
        for _ in 0...retries {
            connected = attempt(endpoint: chosen.endpoint, key: psk(code: code, game: game, role: role), identity: game, timeout: perAttempt)
            attempts.append(connected)
            if connected["state"] as? String == "ready" { break }
        }
        report["attempts"] = attempts.map { $0["state"] ?? "" }
        connected["game"] = game
        report["connect"] = connected
        report["passed"] = connected["state"] as? String == "ready" && connected["role"] as? String == role
            && connected["cipherSuite"] as? String == hex(Int(pinnedSuite)) && pair.count == 2
    } else { report["passed"] = false }
    write(option("--out") ?? "join.json", report)
    print("join: \(report["passed"] as? Bool == true ? "passed" : "FAILED")")
    quit(report["passed"] as? Bool == true ? 0 : 1)
}

/// On-screen windows by owner: the local-network prompt is a window macOS puts up for the app, so it shows here.
func windowsCommand() -> Never {
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    let windows = list.map { ["owner": $0[kCGWindowOwnerName as String] ?? "", "name": $0[kCGWindowName as String] ?? "",
                              "layer": $0[kCGWindowLayer as String] ?? 0, "pid": $0[kCGWindowOwnerPID as String] ?? 0] }
    write(option("--out") ?? "windows.json", ["windows": windows, "at": Date().timeIntervalSince1970])
    quit(0)
}

switch arguments[1] {
case "windows": windowsCommand()
case "serve": serve()
case "connect": connect()
case "probe-a": probeA()
case "probe-b": probeB()
case "browse": browseCommand()
case "join": joinCommand()
default: fail("Unknown command \(arguments[1])")
}
