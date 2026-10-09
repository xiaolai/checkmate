import XCTest
@testable import CheckmateCore
final class ReviewCorpusTests:XCTestCase {
    func testAllManifestTargets()throws {
        let root=ProcessInfo.processInfo.environment["CHECKMATE_REVIEW_CORPUS"].map{URL(fileURLWithPath:$0)} ?? URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/GameReview");var count=0,heldOut=0;var parentSplits:[String:String]=[:]
        for file in ["manifest.json","manifest-expanded.json","manifest-novice.json"] {let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent(file))) as! [String:Any];for entry in manifest["entries"] as! [[String:Any]] {count+=1;let parent=entry["parentId"] as? String ?? entry["id"] as! String,split=entry["split"] as? String ?? "tuning";if let previous=parentSplits[parent]{XCTAssertEqual(previous,split,"Parent grouping leakage: \(parent)")};parentSplits[parent]=split;let data=try Data(contentsOf:root.appendingPathComponent(entry["path"] as! String));XCTAssertEqual(reviewHash(data),entry["sha256"] as? String);if entry["split"] as? String=="held-out"{heldOut+=1};if entry["expectedImport"] as? String=="reject"{XCTAssertThrowsError(try PGNImporter.parse(data),entry["id"] as! String)}else{do{let docs=try PGNImporter.parse(data);for doc in docs{try doc.validate();XCTAssertEqual(PGNExporter.original(doc),doc.original)}}catch{XCTFail("\(entry["id"]!): \(error)")}}}}
        XCTAssertGreaterThanOrEqual(count,80);XCTAssertGreaterThanOrEqual(heldOut,20)
    }
}
