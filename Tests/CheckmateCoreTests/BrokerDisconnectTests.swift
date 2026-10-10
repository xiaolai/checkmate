import XCTest
import Network
@testable import CheckmateCore
@MainActor final class BrokerDisconnectTests:XCTestCase {
    private func fixture(timeout:Double=25)async throws -> (GameSession,CompanionBroker,[String:Any],String) {
        let s=try GameSession(engine:nil),dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),b=try CompanionBroker(session:s,directory:dir,requestTimeout:timeout)
        try b.enable(role:"coach")
        let file=dir.appendingPathComponent("connection.json")
        for _ in 0..<100 {if FileManager.default.fileExists(atPath:file.path){break};try await Task.sleep(nanoseconds:10_000_000)}
        let d=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any],client=UUID().uuidString
        _ = try await post(d,client:client,method:"get_session")
        return (s,b,d,client)
    }
    private func post(_ d:[String:Any],client:String,method:String="get_session",args:[String:Any]=[:],path:String="/rpc")async throws -> [String:Any] {
        var r=URLRequest(url:URL(string:(d["url"] as! String)+path)!);r.httpMethod="POST";r.setValue("Bearer "+(d["token"] as! String),forHTTPHeaderField:"Authorization");r.setValue(client,forHTTPHeaderField:"X-Checkmate-Client")
        r.httpBody=try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"method":method,"args":args]);let (data,_)=try await URLSession.shared.data(for:r);return try JSONSerialization.jsonObject(with:data) as! [String:Any]
    }
    private func waitRequest(_ s:GameSession)->[String:Any]{["sessionId":s.sessionId,"cursor":s.cursor,"timeoutMs":20000]}
    private func until(_ predicate:()->Bool)async throws {for _ in 0..<100{if predicate(){return};try await Task.sleep(nanoseconds:10_000_000)};XCTFail("Broker lifecycle condition timed out")}
    func testDroppedTCPWaitCancelsAndReconnectCanWait()async throws {
        let (s,b,d,client)=try await fixture();defer{b.disable();try? FileManager.default.removeItem(at:b.directory)}
        let url=URL(string:d["url"] as! String)!,c=NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:UInt16(url.port!))!,using:.tcp)
        c.start(queue:.main)
        let body=try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"method":"wait_for_change","args":waitRequest(s)])
        var bytes=Data("POST /rpc HTTP/1.1\r\nHost: 127.0.0.1:\(url.port!)\r\nAuthorization: Bearer \(d["token"] as! String)\r\nX-Checkmate-Client: \(client)\r\nContent-Length: \(body.count)\r\n\r\n".utf8);bytes.append(body);c.send(content:bytes,completion:.contentProcessed{_ in})
        try await until{b.activeRequestCount==1};c.cancel();try await until{b.activeRequestCount==0}
        var args=waitRequest(s);args["timeoutMs"]=100
        let result=try await post(d,client:client,method:"wait_for_change",args:args);XCTAssertEqual(result["changed"] as? Bool,false);XCTAssertNil(result["error"])
    }
    func testRequestDeadlineCancelsWait()async throws {
        let (s,b,d,client)=try await fixture(timeout:0.1);defer{b.disable();try? FileManager.default.removeItem(at:b.directory)}
        let start=Date(),result=try await post(d,client:client,method:"wait_for_change",args:waitRequest(s));XCTAssertEqual((result["error"] as? [String:Any])?["code"] as? String,"CANCELLED");XCTAssertLessThan(Date().timeIntervalSince(start),1);try await until{b.activeRequestCount==0}
    }
    func testExplicitDisconnectCancelsPendingWaitAndReleasesOwner()async throws {
        let (s,b,d,client)=try await fixture();defer{b.disable();try? FileManager.default.removeItem(at:b.directory)}
        let args=waitRequest(s),task=Task{try await self.post(d,client:client,method:"wait_for_change",args:args)}
        try await until{b.activeRequestCount==1};_ = try await post(d,client:client,path:"/disconnect");let result=try await task.value;XCTAssertEqual((result["error"] as? [String:Any])?["code"] as? String,"CANCELLED");XCTAssertNil(s.companionLease);try await until{b.activeRequestCount==0};let fresh=try await post(d,client:UUID().uuidString);XCTAssertNotNil(fresh["sessionId"])
    }
}
