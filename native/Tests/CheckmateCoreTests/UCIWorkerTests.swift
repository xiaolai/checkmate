import XCTest
@testable import CheckmateCore
@MainActor final class UCIWorkerTests:XCTestCase {
    private func executable(stall:Bool=false,delay:Double=0)throws -> (URL,URL){let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);let path=directory.appendingPathComponent("fake.py");let code="""
#!/usr/bin/python3
import sys,time,os
with open(os.path.join(os.path.dirname(__file__),'launches'),'a') as f:f.write('launch\\n')
for raw in sys.stdin:
 s=raw.strip()
 if s=='uci':
  print('id name Fake UCI',flush=True);print('option name Skill Level type spin default 20 min 0 max 20',flush=True);print('option name UCI_LimitStrength type check default false',flush=True);print('uciok',flush=True)
 elif s=='isready':print('readyok',flush=True)
 elif s.startswith('go'):
  with open(os.path.join(os.path.dirname(__file__),'searches'),'a') as f:f.write('go\\n')
  time.sleep(\(delay))
  if \(stall ? "True":"False"):time.sleep(30)
  print('info depth 4 multipv 1 score cp 40 lowerbound nodes 100 time 1 wdl 400 400 200 pv e2e4',flush=True)
  print('info depth 4 multipv 2 score cp 20 nodes 100 time 1 wdl 300 400 300 pv d2d4',flush=True)
  sys.stdout.write('info depth 5 multipv 1 score cp 50 nodes 200 time 2 pv e2');sys.stdout.flush();time.sleep(.01);print('e4',flush=True)
  print('bestmove e2e4',flush=True)
""";try code.write(to:path,atomically:true,encoding:.utf8);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:path.path);return (path,directory)}
    func testBarriersReuseFragmentsAndCoherentDepth()async throws {let (path,directory)=try executable();defer{try? FileManager.default.removeItem(at:directory)};let e=NativeEngine(executable:path),r=try ChessRules();let a=try await e.analyze(fen:r.fen,skill:10,budget:100,multiPv:2);let b=try await e.analyze(fen:r.fen,skill:20,budget:100,multiPv:2);XCTAssertEqual(a.lines.map(\.depth),[4,4]);XCTAssertEqual(a.lines[0].score.bound,"lower");XCTAssertEqual(a.lines[0].wdl,[400,400,200]);XCTAssertEqual(b.bestMove,"e2e4");XCTAssertEqual(try String(contentsOf:directory.appendingPathComponent("launches"),encoding:.utf8),"launch\n")}
    func testCancellationKillsStalledWorker()async throws {let (path,directory)=try executable(stall:true);defer{try? FileManager.default.removeItem(at:directory)};let e=NativeEngine(executable:path),r=try ChessRules(),start=Date();let task=Task{try await e.analyze(fen:r.fen,skill:20,budget:100,multiPv:1)};try await Task.sleep(nanoseconds:100_000_000);task.cancel();do{_ = try await task.value;XCTFail("Cancelled search returned evidence")}catch{};XCTAssertLessThan(Date().timeIntervalSince(start),2)}
    func testCancelledReservedEpochDoesNotLaunch()throws {
        let (path,directory)=try executable();defer{try? FileManager.default.removeItem(at:directory)}
        let worker=UCIWorker(executable:path),epoch=worker.reserve(),fen=try ChessRules().fen;worker.cancel(expected:epoch)
        XCTAssertThrowsError(try worker.search(startFEN:fen,moves:[],finalFEN:fen,profile:.skill(20),budget:100,multiPv:1,searchMoves:[],epoch:epoch))
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("launches").path))
    }
    func testOldEpochCancellationCannotKillNewSearch()async throws {
        let (path,directory)=try executable(delay:0.2);defer{try? FileManager.default.removeItem(at:directory)}
        let worker=UCIWorker(executable:path),old=worker.reserve(),fen=try ChessRules().fen;worker.cancel(expected:old);let current=worker.reserve()
        let task=Task.detached{try worker.search(startFEN:fen,moves:[],finalFEN:fen,profile:.skill(20),budget:500,multiPv:1,searchMoves:[],epoch:current)}
        for _ in 0..<100 where !FileManager.default.fileExists(atPath:directory.appendingPathComponent("searches").path){try await Task.sleep(for:.milliseconds(10))}
        XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent("searches").path));worker.cancel(expected:old)
        let result=try await task.value;XCTAssertEqual(result.bestMove,"e2e4");XCTAssertEqual(try String(contentsOf:directory.appendingPathComponent("launches"),encoding:.utf8),"launch\n")
    }

    func testFailedHistoryCannotPoisonCachedRules()async throws {
        let (path,directory)=try executable();defer{try? FileManager.default.removeItem(at:directory)}
        let engine=NativeEngine(executable:path),fen=try ChessRules().fen
        _ = try await engine.analyzeHistory(startFEN:fen,moves:[],profile:.skill(20),budget:100,multiPv:1)
        do{_ = try await engine.analyzeHistory(startFEN:fen,moves:["e2e4","invalid"],profile:.skill(20),budget:100,multiPv:1);XCTFail("Invalid history accepted")}catch{}
        _ = try await engine.analyzeHistory(startFEN:fen,moves:["d2d4"],profile:.skill(20),budget:100,multiPv:1,searchMoves:["d7d5"])
    }
    func testRuntimePolicyMatchesBundledBuildManifest()throws {
        let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:NativeResources.url("stockfish-build.json"))) as! [String:Any]
        XCTAssertEqual(manifest["networkFile"] as? String,EngineRuntimePolicy.networkFile)
        XCTAssertEqual(manifest["networkSHA256"] as? String,EngineRuntimePolicy.networkSHA256)
    }

}
