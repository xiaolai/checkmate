import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

final class BrokerLifecycleTests:XCTestCase {
    @MainActor func testLeaseExpiresAndFreshOwnerReconnects()async throws {let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let s=try GameSession(engine:nil),b=try CompanionBroker(session:s,directory:dir,leaseTimeout:0.12,heartbeatInterval:0.02);try b.enable(role:"coach");defer{b.disable()};let file=dir.appendingPathComponent("connection.json");for _ in 0..<100{if FileManager.default.fileExists(atPath:file.path){break};try await Task.sleep(nanoseconds:10_000_000)};let d=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        func post(client:String,headers:[String:String]=[:],body:Data?=nil)async throws->[String:Any]{var r=URLRequest(url:URL(string:d["url"] as! String+"/rpc")!);r.httpMethod="POST";r.httpBody=try body ?? JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"method":"get_session","args":[:]]);r.setValue("Bearer "+(d["token"] as! String),forHTTPHeaderField:"Authorization");r.setValue(client,forHTTPHeaderField:"X-Checkmate-Client");for (k,v) in headers{r.setValue(v,forHTTPHeaderField:k)};let (data,_)=try await URLSession.shared.data(for:r);return try JSONSerialization.jsonObject(with:data) as! [String:Any]}
        let owner=UUID().uuidString,other=UUID().uuidString;_ = try await post(client:owner);let rejected=try await post(client:other);XCTAssertEqual((rejected["error"] as? [String:Any])?["code"] as? String,"SESSION_IN_USE")
        for h in [["Host":"localhost:1"],["Authorization":"Bearer wrong"]]{let value=try await post(client:owner,headers:h);XCTAssertEqual((value["error"] as? [String:Any])?["code"] as? String,"NOT_AUTHORIZED")}
        let malformed=try await post(client:owner,body:Data("[]".utf8));XCTAssertEqual((malformed["error"] as? [String:Any])?["code"] as? String,"INVALID_ARGUMENT")
        try await Task.sleep(nanoseconds:250_000_000);XCTAssertFalse(b.connected);XCTAssertNil(s.companionLease);let fresh=try await post(client:other);XCTAssertNotNil(fresh["sessionId"]);XCTAssertTrue(b.connected)
    }
}

/// Hidden apps stay suspended when a lease expires, the learner's Disconnect really disconnects that client,
/// and a crash's connection file is never left for a client to find.
@MainActor final class BrokerControlTests:XCTestCase {
    private func broker(_ dir:URL,_ s:GameSession,lease:TimeInterval=35)async throws -> (CompanionBroker,(String)async throws->[String:Any]) {
        let b=try CompanionBroker(session:s,directory:dir,leaseTimeout:lease,heartbeatInterval:0.02);try b.enable(role:"coach")
        let file=dir.appendingPathComponent("connection.json");for _ in 0..<100{if FileManager.default.fileExists(atPath:file.path){break};try await Task.sleep(nanoseconds:10_000_000)}
        let d=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        func post(_ client:String)async throws -> [String:Any] {var r=URLRequest(url:URL(string:d["url"] as! String+"/rpc")!);r.httpMethod="POST";r.httpBody=try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"method":"get_session","args":[:]]);r.setValue("Bearer "+(d["token"] as! String),forHTTPHeaderField:"Authorization");r.setValue(client,forHTTPHeaderField:"X-Checkmate-Client");let (data,_)=try await URLSession.shared.data(for:r);return try JSONSerialization.jsonObject(with:data) as! [String:Any]}
        return (b,post)
    }
    private func code(_ value:[String:Any])->String? {(value["error"] as? [String:Any])?["code"] as? String}
    func testLeaseExpiryWhileHiddenKeepsTheAppSuspended()async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let s=try GameSession(engine:nil),(b,post)=try await broker(dir,s,lease:0.12);defer{b.disable()}
        _ = try await post(UUID().uuidString);XCTAssertTrue(b.connected)
        b.suspend(true);XCTAssertTrue(s.suspended)
        try await Task.sleep(nanoseconds:300_000_000);XCTAssertFalse(b.connected,"The lease expired")
        XCTAssertTrue(s.suspended,"An expired lease must not resume a hidden app");let hidden=try await post(UUID().uuidString);XCTAssertEqual(code(hidden),"APP_SUSPENDED")
        b.suspend(false);XCTAssertFalse(s.suspended)
    }
    func testDisconnectCompanionRevokesThatClientOnly()async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let s=try GameSession(engine:nil),(b,post)=try await broker(dir,s);defer{b.disable()}
        let first=UUID().uuidString;_ = try await post(first);XCTAssertTrue(b.connected)
        b.disconnectCurrentClient();XCTAssertFalse(b.connected)
        let again=try await post(first);XCTAssertEqual(code(again),"DISCONNECTED_BY_USER");XCTAssertFalse(b.connected)
        let fresh=try await post(UUID().uuidString);XCTAssertNotNil(fresh["sessionId"],"A new Codex task can still connect")
    }
    func testAStaleConnectionFileIsRemovedAtStartup()throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);let file=dir.appendingPathComponent("connection.json")
        try Data("{\"schemaVersion\":1,\"url\":\"http://127.0.0.1:9\",\"token\":\"old\"}".utf8).write(to:file)
        _ = try CompanionBroker(session:try GameSession(engine:nil),directory:dir);XCTAssertFalse(FileManager.default.fileExists(atPath:file.path))
    }
}
