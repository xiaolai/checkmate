import XCTest
@testable import CheckmateCore
@MainActor final class EngineGoldenTests:XCTestCase {
    func testHeldOutStrongEvidence()async throws {
        guard let corpus=ProcessInfo.processInfo.environment["CHECKMATE_REVIEW_CORPUS"],let destination=ProcessInfo.processInfo.environment["CHECKMATE_ENGINE_GOLD"] else{throw XCTSkip("Explicit build-host strong held-out evidence generation gate.")}
        let root=URL(fileURLWithPath:corpus),engine=NativeEngine();var rows:[[String:Any]]=[],stableCount=0
        let manifests=["manifest-expanded.json","manifest-novice.json"]
        for name in manifests {let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent(name))) as! [String:Any]
            for entry in manifest["entries"] as! [[String:Any]] where entry["expectedImport"] as? String=="accept" && entry["split"] as? String=="held-out" {
                let document=try PGNImporter.parse(Data(contentsOf:root.appendingPathComponent(entry["path"] as! String)))[0]
                let node=document.mainline.first ?? 0,history=try document.history(to:node),rules=try document.rules(at:node),status=try document.status(at:node)
                if status.terminal{rows.append(["id":entry["id"]!,"parentId":entry["parentId"]!,"terminal":true,"positionStatus":jsonObject(status),"historyHash":try document.historyHash(to:node),"noContinuation":true]);continue}
                var samples:[EngineAnalysis]=[]
                for _ in 0..<2{samples.append(try await engine.analyzeHistory(startFEN:document.startingFEN,moves:history,profile:.skill(20),budget:3000,multiPv:min(3,rules.moves().count)))}
                for sample in samples {for line in sample.lines {let replay=try rules.copy();for move in line.pv{XCTAssertNoThrow(try replay.move(uci:move),entry["id"] as! String)}}}
                let a=samples[0].lines.first,b=samples[1].lines.first,stable=a?.pv.first==b?.pv.first && a?.score.kind==b?.score.kind && a?.score.bound==nil && b?.score.bound==nil && (a?.score.kind=="mate" ? a?.score.value==b?.score.value:abs((a?.score.value ?? 0)-(b?.score.value ?? 0))<=30)
                if stable{stableCount+=1}
                let row:[String:Any]=["id":entry["id"]!,"parentId":entry["parentId"]!,"split":"held-out","nodeId":node,"startFEN":document.startingFEN,"moves":history,"historyHash":try document.historyHash(to:node),"engine":engine.capabilities.name,"engineHash":engine.binaryIdentity,"options":AnalysisPolicy.options,"budgetMs":3000,"samples":samples.map{jsonObject($0)},"stableCandidate":stable,"allPVEdgesLegal":true,"scorePerspective":"white","humanRubric":"Pending; these are independent engine/rules observations, not human coaching-quality approval."]
                rows.append(row);try JSONSerialization.data(withJSONObject:["schemaVersion":1,"rows":rows,"stableCount":stableCount],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:destination),options:.atomic)
            }
        };XCTAssertGreaterThanOrEqual(rows.count,20)
    }
}
