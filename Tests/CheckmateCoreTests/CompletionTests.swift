import XCTest
@testable import CheckmateCore
final class CompletionTests:XCTestCase {
    func testNonFiniteAndOddPCM(){XCTAssertEqual(VoicePCM.decode(VoicePCM.encode([.nan,.infinity,-.infinity])),[0,0,0]);XCTAssertEqual(VoicePCM.decode(Data()),[]);XCTAssertEqual(VoicePCM.decode(Data([0])),[])}
    @MainActor func testThousandTransitionsAndDispatchBudget()throws {
        let s=try GameSession(engine:nil);var elapsed:[Double]=[]
        func dispatch(_ body:()throws->Void)rethrows {let start=Date();try body();elapsed.append(Date().timeIntervalSince(start))}
        for _ in 0..<250 {try dispatch{try s.select("e2")};try dispatch{try s.select("e4")};try dispatch{_ = try s.commitBlack("e7e5")};dispatch{s.undo()};XCTAssertTrue(s.rules.history.isEmpty);XCTAssertNil(s.preview);XCTAssertNil(s.demonstration);XCTAssertFalse(s.busy)}
        elapsed.sort();let p95=elapsed[Int(Double(elapsed.count-1)*0.95)]*1000;print("PERFORMANCE dispatch-p95-ms=\(p95) transitions=1000");XCTAssertLessThan(p95,50);s.prepareShutdown();XCTAssertNil(s.voiceLease)
    }
    @MainActor func testTwentyBrokerCyclesAndPrivateDiscovery()async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let s=try GameSession(engine:nil),b=try CompanionBroker(session:s,directory:dir)
        for _ in 0..<20 {try b.enable(role:"coach");let url=dir.appendingPathComponent("connection.json");for _ in 0..<100{if FileManager.default.fileExists(atPath:url.path){break};try await Task.sleep(nanoseconds:10_000_000)};XCTAssertTrue(FileManager.default.fileExists(atPath:url.path));let d=try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any];let client=UUID().uuidString
            func post(_ body:Data,origin:Bool=false)async throws->[String:Any]{var r=URLRequest(url:URL(string:d["url"] as! String+"/rpc")!);r.httpMethod="POST";r.httpBody=body;r.setValue("Bearer "+(d["token"] as! String),forHTTPHeaderField:"Authorization");r.setValue(client,forHTTPHeaderField:"X-Checkmate-Client");if origin{r.setValue("http://invalid",forHTTPHeaderField:"Origin")};let (data,_)=try await URLSession.shared.data(for:r);return try JSONSerialization.jsonObject(with:data) as! [String:Any]}
            let payload=try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"method":"get_session","args":[:]])
            let rejected=try await post(payload,origin:true);XCTAssertNotNil(rejected["error"])
            let result=try await post(payload);XCTAssertNotNil(result["sessionId"]);XCTAssertTrue(b.connected)
            let malformed=try await post(Data("{".utf8));let error=malformed["error"] as? [String:Any];XCTAssertEqual(error?["code"] as? String,"INVALID_ARGUMENT")
            let perms=try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as! NSNumber;XCTAssertEqual(perms.intValue & 0o777,0o600)
            b.disable();XCTAssertFalse(b.connected);XCTAssertNil(s.companionLease);XCTAssertFalse(FileManager.default.fileExists(atPath:url.path));try await Task.sleep(nanoseconds:10_000_000);XCTAssertEqual(b.activeRequestCount,0);XCTAssertEqual(b.activeConnectionCount,0)
        };s.prepareShutdown()
    }
    @MainActor func testWaitBudget()async throws {let s=try GameSession(engine:nil),t=try CompanionTools(session:s);s.setConnection(enabled:true,role:"coach",lease:"test");let start=Date();_ = try await t.call("wait_for_change",args:["sessionId":s.sessionId,"cursor":s.cursor,"timeoutMs":100],lease:"test");XCTAssertLessThan(Date().timeIntervalSince(start),1.1)}
}
