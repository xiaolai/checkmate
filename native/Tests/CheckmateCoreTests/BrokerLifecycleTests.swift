import XCTest
@testable import CheckmateCore
final class BrokerLifecycleTests:XCTestCase {
    @MainActor func testLeaseExpiresAndFreshOwnerReconnects()async throws {let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)};let s=try GameSession(engine:nil),b=try CompanionBroker(session:s,directory:dir,leaseTimeout:0.12,heartbeatInterval:0.02);try b.enable(role:"coach");defer{b.disable()};let file=dir.appendingPathComponent("connection.json");for _ in 0..<100{if FileManager.default.fileExists(atPath:file.path){break};try await Task.sleep(nanoseconds:10_000_000)};let d=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
        func post(client:String,headers:[String:String]=[:],body:Data?=nil)async throws->[String:Any]{var r=URLRequest(url:URL(string:d["url"] as! String+"/rpc")!);r.httpMethod="POST";r.httpBody=try body ?? JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"method":"get_session","args":[:]]);r.setValue("Bearer "+(d["token"] as! String),forHTTPHeaderField:"Authorization");r.setValue(client,forHTTPHeaderField:"X-Checkmate-Client");for (k,v) in headers{r.setValue(v,forHTTPHeaderField:k)};let (data,_)=try await URLSession.shared.data(for:r);return try JSONSerialization.jsonObject(with:data) as! [String:Any]}
        let owner=UUID().uuidString,other=UUID().uuidString;_ = try await post(client:owner);let rejected=try await post(client:other);XCTAssertEqual((rejected["error"] as? [String:Any])?["code"] as? String,"SESSION_IN_USE")
        for h in [["Host":"localhost:1"],["Authorization":"Bearer wrong"]]{let value=try await post(client:owner,headers:h);XCTAssertEqual((value["error"] as? [String:Any])?["code"] as? String,"NOT_AUTHORIZED")}
        let malformed=try await post(client:owner,body:Data("[]".utf8));XCTAssertEqual((malformed["error"] as? [String:Any])?["code"] as? String,"INVALID_ARGUMENT")
        try await Task.sleep(nanoseconds:250_000_000);XCTAssertFalse(b.connected);XCTAssertNil(s.companionLease);let fresh=try await post(client:other);XCTAssertNotNil(fresh["sessionId"]);XCTAssertTrue(b.connected)
    }
}
