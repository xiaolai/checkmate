import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

@MainActor final class UCIWorkerTests:XCTestCase {
    /// A fake engine. `hold` keeps each search waiting until the test writes `release`; `handshakeStall` never answers
    /// `uci`. It records every launch (with its process ID), every position and every search.
    private func executable(stall:Bool=false,delay:Double=0,startupDelay:Double=0,hold:Bool=false,handshakeStall:Bool=false)throws -> (URL,URL){let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);let path=directory.appendingPathComponent("fake.py");let code="""
#!/usr/bin/python3
import sys,time,os
here=os.path.dirname(__file__)
def note(name,text):
 with open(os.path.join(here,name),'a') as f:f.write(text+'\\n')
note('launches','launch')
note('pids',str(os.getpid()))
time.sleep(\(startupDelay))
moved=False
for raw in sys.stdin:
 s=raw.strip()
 if s=='uci' and \(handshakeStall ? "True":"False"):
  note('handshakes','uci');time.sleep(30);sys.exit(0)
 if s.startswith('position'):
  note('positions',s);moved=' moves ' in s
 elif s=='uci':
  print('id name Fake UCI',flush=True);print('option name Skill Level type spin default 20 min 0 max 20',flush=True);print('option name UCI_LimitStrength type check default false',flush=True);print('uciok',flush=True)
 elif s=='isready':print('readyok',flush=True)
 elif s.startswith('go'):
  note('searches',s)
  time.sleep(\(delay))
  if \(stall ? "True":"False"):time.sleep(30)
  if \(hold ? "True":"False"):
   for _ in range(3000):
    if os.path.exists(os.path.join(here,'release')):break
    time.sleep(.01)
  first,second=('e7e5','d7d5') if moved else ('e2e4','d2d4')
  if ' searchmoves ' in s:first=s.split(' searchmoves ')[1].split()[0]
  print('info depth 4 multipv 1 score cp 40 lowerbound nodes 100 time 1 wdl 400 400 200 pv '+first,flush=True)
  print('info depth 4 multipv 2 score cp 20 nodes 100 time 1 wdl 300 400 300 pv '+second,flush=True)
  sys.stdout.write('info depth 5 multipv 1 score cp 50 nodes 200 time 2 pv '+first[:2]);sys.stdout.flush();time.sleep(.01);print(first[2:],flush=True)
  print('bestmove '+first,flush=True)
""";try code.write(to:path,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path);return (path,directory)}
    func testBarriersReuseFragmentsAndCoherentDepth()async throws {let (path,directory)=try executable();defer{try? FileManager.default.removeItem(at:directory)};let e=NativeEngine(executable:path),r=try ChessRules();let a=try await e.analyze(fen:r.fen,skill:10,budget:100,multiPv:2);let b=try await e.analyze(fen:r.fen,skill:20,budget:100,multiPv:2);XCTAssertEqual(a.lines.map(\.depth),[4,4]);let first=try XCTUnwrap(a.lines.first);XCTAssertEqual(first.score.bound,"lower");XCTAssertEqual(first.wdl,[400,400,200]);XCTAssertEqual(b.bestMove,"e2e4")
        // One line: the depth-five line, which arrives in two fragments, is put back together whole.
        let c=try await e.analyze(fen:r.fen,skill:20,budget:100,multiPv:1),deepest=try XCTUnwrap(c.lines.first)
        XCTAssertEqual(deepest.depth,5);XCTAssertEqual(deepest.score.value,50);XCTAssertNil(deepest.score.bound);XCTAssertEqual(deepest.pv.first,"e2e4")
        XCTAssertEqual(try String(contentsOf:directory.appendingPathComponent("launches"),encoding:.utf8),"launch\n")}
    private func file(_ directory:URL,_ name:String)->URL {directory.appendingPathComponent(name)}
    private func lines(_ directory:URL,_ name:String)throws -> [String] {try String(contentsOf:file(directory,name),encoding:.utf8).split(separator:"\n").map(String.init)}
    /// Waits up to the worker's own startup allowance for the fake to write `name`.
    private func appears(_ directory:URL,_ name:String)async throws -> Bool {for _ in 0..<1100 where !FileManager.default.fileExists(atPath:file(directory,name).path){try await Task.sleep(for:.milliseconds(10))};return FileManager.default.fileExists(atPath:file(directory,name).path)}
    private func ended(_ pid:pid_t)async throws -> Bool {for _ in 0..<200 where kill(pid,0)==0{try await Task.sleep(for:.milliseconds(10))};return kill(pid,0) != 0}
    /// Runs with no calibration override, whatever the environment says, so the commands the worker sends are its own.
    private func withoutCalibration<T>(_ work:()async throws->T)async rethrows -> T {
        let saved=getenv("CHECKMATE_CALIBRATION_NODES").map{String(cString:$0)};unsetenv("CHECKMATE_CALIBRATION_NODES")
        defer{if let saved{setenv("CHECKMATE_CALIBRATION_NODES",saved,1)}}
        return try await work()
    }
    /// What a cancelled search can report: the cancellation itself, or the pipe its killed process closed.
    static func endedByCancellation(_ error:Error)->Bool {
        if error is CancellationError{return true}
        switch error as? CheckmateError {case .cancelled?:return true;case .unavailable(let reason)?:return reason=="Engine stopped responding.";default:return false}
    }
    func testCancellationKillsStalledWorker()async throws {
        let (path,directory)=try executable(stall:true);defer{try? FileManager.default.removeItem(at:directory)}
        // A one-second search: the worker's own watchdog fires only after three seconds, so an end within two seconds
        // of cancelling is the cancellation's doing.
        let e=NativeEngine(executable:path),r=try ChessRules();let task=Task{try await e.analyze(fen:r.fen,skill:20,budget:1000,multiPv:1)}
        let searching=try await appears(directory,"searches");XCTAssertTrue(searching,"the search reached the engine before it was cancelled")
        let start=Date(),pid=try XCTUnwrap(pid_t(try lines(directory,"pids").last ?? ""));XCTAssertEqual(kill(pid,0),0,"the search is still running when cancelled");task.cancel()
        do{_ = try await task.value;XCTFail("Cancelled search returned evidence")}catch{XCTAssertTrue(Self.endedByCancellation(error),"an unrelated failure: \(error)")}
        XCTAssertLessThan(Date().timeIntervalSince(start),2);let stopped=try await ended(pid);XCTAssertTrue(stopped,"the stalled process was killed")
    }
    func testCancelledReservedEpochDoesNotLaunch()throws {
        let (path,directory)=try executable();defer{try? FileManager.default.removeItem(at:directory)}
        let worker=UCIWorker(executable:path),epoch=worker.reserve(),fen=try ChessRules().fen;worker.cancel(expected:epoch)
        XCTAssertThrowsError(try worker.search(startFEN:fen,moves:[],finalFEN:fen,profile:.skill(20),limit:.movetime(100),multiPv:1,searchMoves:[],epoch:epoch))
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("launches").path))
    }
    func testOldEpochCancellationCannotKillNewSearch()async throws {
        // The search is held inside the engine until released, so the stale cancellation lands while it is running.
        let (path,directory)=try executable(hold:true);defer{try? FileManager.default.removeItem(at:directory)}
        let worker=UCIWorker(executable:path),old=worker.reserve(),fen=try ChessRules().fen;worker.cancel(expected:old);let current=worker.reserve()
        let task=Task.detached{try worker.search(startFEN:fen,moves:[],finalFEN:fen,profile:.skill(20),limit:.movetime(2000),multiPv:1,searchMoves:[],epoch:current)}
        let searching=try await appears(directory,"searches");XCTAssertTrue(searching,"the search started");worker.cancel(expected:old)
        try Data().write(to:file(directory,"release"))
        let result=try await task.value;XCTAssertEqual(result.bestMove,"e2e4");XCTAssertEqual(try lines(directory,"launches"),["launch"])
    }

    /// Assistance plan A5: a node limit reaches the engine as `go nodes`, bounded, with no time budget; a time is still
    /// `go movetime`.
    func testANodeLimitIsSentAsGoNodes()async throws {
        let (path,directory)=try executable();defer{try? FileManager.default.removeItem(at:directory)}
        let engine=NativeEngine(executable:path),fen=try ChessRules().fen
        try await withoutCalibration {
            // After 1. e4 the fake answers for Black, so the line is legal there and survives the engine's replay.
            let nodes=try await engine.analyzeHistory(startFEN:fen,moves:["e2e4"],profile:.skill(20),limit:.nodes(NetworkAssistance.hintNodes),multiPv:1)
            XCTAssertEqual(nodes.budgetMs,0);XCTAssertEqual(nodes.bestMove,"e7e5");XCTAssertEqual(nodes.lines.first?.pv.first,"e7e5");XCTAssertEqual(nodes.lines.first?.san.first,"e5")
            _ = try await engine.analyzeHistory(startFEN:fen,moves:[],profile:.skill(20),limit:.nodes(1),multiPv:1)
            _ = try await engine.analyzeHistory(startFEN:fen,moves:[],profile:.skill(20),limit:.movetime(350),multiPv:1)
            _ = try await engine.analyzeHistory(startFEN:fen,moves:[],profile:.skill(20),budget:350,multiPv:1)
        }
        XCTAssertEqual(try lines(directory,"searches"),["go nodes 400000","go nodes 1000","go movetime 350","go movetime 350"])
    }
    /// A silent run's calibration node count replaces either limit: the override the measurements rely on.
    func testCalibrationNodesReplaceEitherLimit()async throws {
        let (path,directory)=try executable();defer{try? FileManager.default.removeItem(at:directory)}
        let engine=NativeEngine(executable:path),fen=try ChessRules().fen,saved=getenv("CHECKMATE_CALIBRATION_NODES").map{String(cString:$0)}
        setenv("CHECKMATE_CALIBRATION_NODES","5000",1);defer{if let saved{setenv("CHECKMATE_CALIBRATION_NODES",saved,1)}else{unsetenv("CHECKMATE_CALIBRATION_NODES")}}
        _ = try await engine.analyzeHistory(startFEN:fen,moves:[],profile:.skill(20),limit:.nodes(NetworkAssistance.hintNodes),multiPv:1)
        _ = try await engine.analyzeHistory(startFEN:fen,moves:[],profile:.skill(20),limit:.movetime(350),multiPv:1)
        XCTAssertEqual(try lines(directory,"searches"),["go nodes 5000","go nodes 5000"])
    }
    /// chess.js accepts a FEN whose fields are separated by a line break, but Stockfish reads one command per line: the
    /// engine is sent the position as the rules write it, and the worker refuses a line break outright.
    func testAStartFENIsSentAsOneLine()async throws {
        let (path,directory)=try executable();defer{try? FileManager.default.removeItem(at:directory)}
        let fen=try ChessRules().fen,broken=fen.replacingOccurrences(of:" w ",with:"\nw ")
        XCTAssertNotEqual(broken,fen);XCTAssertEqual(try ChessRules(fen:broken).fen,fen,"fixture: the rules accept the broken FEN")
        let engine=NativeEngine(executable:path)
        _ = try await engine.analyzeHistory(startFEN:broken,moves:[],profile:.skill(20),budget:100,multiPv:1)
        _ = try await engine.analyzeHistory(startFEN:broken,moves:["e2e4"],profile:.skill(20),budget:100,multiPv:1)
        XCTAssertEqual(try lines(directory,"positions"),["position fen \(fen)","position fen \(fen) moves e2e4"])
        let worker=UCIWorker(executable:path),epoch=worker.reserve()
        XCTAssertThrowsError(try worker.search(startFEN:broken,moves:[],finalFEN:fen,profile:.skill(20),limit:.movetime(100),multiPv:1,searchMoves:[],epoch:epoch))
    }
    /// A handshake that never answers is stopped by its watchdog even when a search reserves the worker meanwhile,
    /// which used to make the watchdog's cancellation a no-op and leave both waiting for good.
    func testAStalledStartupStopsEvenAfterANewerSearchReserves()async throws {
        let (path,directory)=try executable(handshakeStall:true);defer{try? FileManager.default.removeItem(at:directory)}
        let allowance:TimeInterval=2,worker=UCIWorker(executable:path,startupAllowance:allowance),fen=try ChessRules().fen,start=Date()
        let preparing=Task.detached{try worker.prepare()}
        let handshaking=try await appears(directory,"handshakes");XCTAssertTrue(handshaking,"the handshake started")
        // The watchdog's timer starts after `start`, so a reservation made within the allowance lands while the
        // preparation is still blocked in its handshake: the race this test is about, not a startup already failed.
        let epoch=worker.reserve();XCTAssertNotNil(worker.startup,"the preparation is still starting");XCTAssertLessThan(Date().timeIntervalSince(start),allowance)
        let searching=Task.detached{try worker.search(startFEN:fen,moves:[],finalFEN:fen,profile:.skill(20),limit:.movetime(100),multiPv:1,searchMoves:[],epoch:epoch)}
        do{_ = try await preparing.value;XCTFail("a stalled handshake prepared the engine")}catch{}
        do{_ = try await searching.value;XCTFail("a stalled engine answered a search")}catch{}
        XCTAssertLessThan(Date().timeIntervalSince(start),8,"both ended within their startup allowances, not the fake's 30 s stall")
        for pid in try lines(directory,"pids").compactMap({pid_t($0)}){let stopped=try await ended(pid);XCTAssertTrue(stopped,"process \(pid) was stopped")}
    }

    /// A startup watchdog that fires late, after its own startup ended and a newer one began, stops nothing: it names
    /// its own startup, and the newer one prepares the engine and keeps its process.
    func testALateWatchdogCannotStopANewerStartup()async throws {
        let (path,directory)=try executable(startupDelay:1);defer{try? FileManager.default.removeItem(at:directory)}
        let worker=UCIWorker(executable:path,startupAllowance:5),epoch=worker.reserve()
        let preparing=Task.detached{try worker.prepare()}
        let launched=try await appears(directory,"pids");XCTAssertTrue(launched,"the newer startup launched")
        let current=try XCTUnwrap(worker.startup,"the newer startup is in progress")
        worker.abandonStartup(current-1,epoch:epoch)
        _ = try await preparing.value
        let pid=try XCTUnwrap(pid_t(try lines(directory,"pids").last ?? ""));XCTAssertEqual(kill(pid,0),0,"the newer startup's process is alive")
        XCTAssertNil(worker.startup);XCTAssertEqual(try lines(directory,"launches"),["launch"])
        worker.cancel()
    }

    func testFailedHistoryCannotPoisonCachedRules()async throws {
        let (path,directory)=try executable();defer{try? FileManager.default.removeItem(at:directory)}
        let engine=NativeEngine(executable:path),fen=try ChessRules().fen
        _ = try await engine.analyzeHistory(startFEN:fen,moves:[],profile:.skill(20),budget:100,multiPv:1)
        do{_ = try await engine.analyzeHistory(startFEN:fen,moves:["e2e4","invalid"],profile:.skill(20),budget:100,multiPv:1);XCTFail("Invalid history accepted")}catch{}
        try await withoutCalibration {
            let constrained=try await engine.analyzeHistory(startFEN:fen,moves:["d2d4"],profile:.skill(20),budget:100,multiPv:1,searchMoves:["d7d5"])
            XCTAssertEqual(constrained.bestMove,"d7d5");XCTAssertEqual(try lines(directory,"searches").last,"go movetime 100 searchmoves d7d5")
        }
    }
    /// A cold start (network load, first-run security scan, a slow Mac) is not charged to the search deadline.
    func testSlowStartupDoesNotFailAShortSearch()async throws {
        let (path,directory)=try executable(startupDelay:2.5);defer{try? FileManager.default.removeItem(at:directory)}
        let result=try await NativeEngine(executable:path).analyze(fen:try ChessRules().fen,skill:20,budget:100,multiPv:1)
        XCTAssertEqual(result.bestMove,"e2e4")
    }
    func testRuntimePolicyMatchesBundledBuildManifest()throws {
        let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("stockfish-build.json"))) as! [String:Any]
        XCTAssertEqual(manifest["networkFile"] as? String,EngineRuntimePolicy.networkFile)
        XCTAssertEqual(manifest["networkSHA256"] as? String,EngineRuntimePolicy.networkSHA256)
    }

}
