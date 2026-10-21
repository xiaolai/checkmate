import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateEngine
@testable import CheckmateContent
@testable import CheckmateApplication
@testable import CheckmateMacPlatform

final class ReviewStoreTests:XCTestCase {
    func testSaveRecoveryAndCorruptQuarantine()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let store=ReviewStore(directory:directory),d=try PGNImporter.parse(Data("1. e4 *".utf8))[0]
        try store.save(d,cursor:1,branches:[]);XCTAssertEqual(try store.load(d.id).document,d)
        try Data("corrupt".utf8).write(to:store.documentURL(d.id));XCTAssertTrue(try store.list().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent("Quarantine").path))
    }
    func testRecoveryIndexAndExport()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let store=ReviewStore(directory:directory),d=try PGNImporter.parse(Data("1. d4 (1. e4) d5 *".utf8))[0]
        try store.save(d,cursor:0,branches:[]);try FileManager.default.removeItem(at:directory.appendingPathComponent("index.json"));XCTAssertEqual(try store.list().count,1)
        XCTAssertEqual(try PGNImporter.parse(store.export(d.id))[0].nodes,d.nodes)
    }
    func testInjectedDiskFullPreservesAtomicWritesAndRecovers()throws {
        for target in ["document","cursor","index"] {
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
            let d=try PGNImporter.parse(Data("1. d4 d5 *".utf8))[0],normal=ReviewStore(directory:directory)
            try normal.save(d,cursor:0,branches:[])
            let url=target=="document" ? normal.documentURL(d.id):directory.appendingPathComponent(target=="cursor" ? d.id.uuidString+".cursor.json":"index.json")
            let before=try Data(contentsOf:url)
            var inject=true
            let failing=ReviewStore(directory:directory,atomicWriter:{data,destination in
                if inject && destination==url {throw NSError(domain:NSPOSIXErrorDomain,code:Int(ENOSPC))}
                try data.write(to:destination,options:.atomic)
            })
            var branch=ReviewBranch(root:0);branch.moves=["e2e4"]
            XCTAssertThrowsError(try failing.save(d,cursor:1,branches:[branch])) {error in XCTAssertEqual((error as NSError).code,Int(ENOSPC))}
            XCTAssertEqual(try Data(contentsOf:url),before,"Failed atomic target must preserve old bytes")
            let recovered=ReviewStore(directory:directory)
            XCTAssertEqual(try recovered.export(d.id),d.original)
            XCTAssertEqual(try recovered.list().count,1)
            let state=try recovered.load(d.id)
            XCTAssertEqual(state.cursor,target=="document" ? 0:1)
            inject=false;try failing.save(d,cursor:2,branches:[branch])
            let reread=try ReviewStore(directory:directory).load(d.id)
            XCTAssertEqual(reread.cursor,2);XCTAssertEqual(reread.branches,[branch])
        }
    }
    func testNewRecordSurvivesIndexDiskFullAndRestart()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let old=try PGNImporter.parse(Data("1. e4 *".utf8))[0],new=try PGNImporter.parse(Data("1. d4 *".utf8))[0]
        try ReviewStore(directory:directory).save(old,cursor:0,branches:[])
        let failing=ReviewStore(directory:directory,atomicWriter:{data,url in
            if url.lastPathComponent=="index.json"{throw NSError(domain:NSPOSIXErrorDomain,code:Int(ENOSPC))}
            try data.write(to:url,options:.atomic)
        })
        XCTAssertThrowsError(try failing.save(new,cursor:1,branches:[]))
        let recovered=ReviewStore(directory:directory)
        XCTAssertEqual(Set(try recovered.list().map(\.id)),[old.id,new.id])
        XCTAssertEqual(try recovered.export(new.id),new.original)
    }
    func testOldSchemaDowngradePreservesBytesAndLegacyCursor()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let store=ReviewStore(directory:directory),d=try PGNImporter.parse(Data("[Event \"Preserve study\"]\n1. d4 (1. e4 {idea}) d5 *".utf8))[0]
        try store.save(d,cursor:2,branches:[])
        // Schema1 record without the newer sidecars remains readable and exactly exportable.
        try FileManager.default.removeItem(at:directory.appendingPathComponent(d.id.uuidString+".cursor.json"))
        try FileManager.default.removeItem(at:directory.appendingPathComponent("index.json"))
        XCTAssertEqual(try ReviewStore(directory:directory).load(d.id).cursor,2)
        XCTAssertEqual(try store.export(d.id),d.original)
        let url=store.documentURL(d.id),original=try Data(contentsOf:url)
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:original) as? [String:Any]);object["schemaVersion"]=2;object["document"]=nil;object["futurePayload"]=["unknown":"format"]
        let future=try JSONSerialization.data(withJSONObject:object);try future.write(to:url,options:.atomic)
        XCTAssertThrowsError(try ReviewStore(directory:directory).load(d.id))
        XCTAssertTrue(try ReviewStore(directory:directory).list().isEmpty)
        XCTAssertEqual(try Data(contentsOf:url),future)
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent("Quarantine").path))
        if let path=ProcessInfo.processInfo.environment["CHECKMATE_STORAGE_ACCEPTANCE_DIR"] {
            let evidence=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:evidence,withIntermediateDirectories:true)
            try original.write(to:evidence.appendingPathComponent("legacy-schema1.json"))
            try future.write(to:evidence.appendingPathComponent("future-schema2-preserved.json"))
            try d.original.write(to:evidence.appendingPathComponent("export-before-downgrade.pgn"))
        }
        object["schemaVersion"]=0;let unsupportedOld=try JSONSerialization.data(withJSONObject:object);try unsupportedOld.write(to:url,options:.atomic)
        XCTAssertThrowsError(try ReviewStore(directory:directory).load(d.id));XCTAssertEqual(try Data(contentsOf:url),unsupportedOld)
        try original.write(to:url,options:.atomic)
        let export=try ReviewStore(directory:directory).export(d.id);XCTAssertEqual(export,d.original)
        XCTAssertEqual(try PGNImporter.parse(export)[0].nodes,d.nodes)
        if let path=ProcessInfo.processInfo.environment["CHECKMATE_STORAGE_ACCEPTANCE_DIR"] {try export.write(to:URL(fileURLWithPath:path).appendingPathComponent("export-after-restore.pgn"))}
    }
    func testCursorOnlyDiskFullThenRetry()throws {
        for target in ["cursor","index"] {
            let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
            let d=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0];var fail=false
            let store=ReviewStore(directory:directory,atomicWriter:{data,url in
                if fail && (target=="index" ? url.lastPathComponent=="index.json":url.lastPathComponent.hasSuffix(".cursor.json")){throw NSError(domain:NSPOSIXErrorDomain,code:Int(ENOSPC))}
                try data.write(to:url,options:.atomic)
            })
            try store.save(d,cursor:0,branches:[])
            let documentBytes=try Data(contentsOf:store.documentURL(d.id));fail=true
            XCTAssertThrowsError(try store.save(d,cursor:1,branches:[]))
            XCTAssertEqual(try Data(contentsOf:store.documentURL(d.id)),documentBytes)
            let fresh=ReviewStore(directory:directory);XCTAssertEqual(try fresh.export(d.id),d.original)
            XCTAssertEqual(try fresh.load(d.id).cursor,target=="cursor" ? 0:1)
            fail=false;try store.save(d,cursor:2,branches:[])
            XCTAssertEqual(try ReviewStore(directory:directory).load(d.id).cursor,2)
        }
    }
    func testChangedDocumentSameIdentityPersistsInsteadOfCursorOnly()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let store=ReviewStore(directory:directory),old=try PGNImporter.parse(Data("1. e4 *".utf8))[0],replacement=try PGNImporter.parse(Data("1. d4 *".utf8))[0]
        var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(replacement)) as? [String:Any]);object["id"]=old.id.uuidString
        let changed=try JSONDecoder().decode(GameDocument.self,from:JSONSerialization.data(withJSONObject:object))
        try store.save(old,cursor:0,branches:[]);try store.save(changed,cursor:1,branches:[])
        XCTAssertEqual(try ReviewStore(directory:directory).export(old.id),replacement.original)
    }
    func testFutureRecordDoesNotBlockCurrentLibraryAndCannotBeOverwritten()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let store=ReviewStore(directory:directory),future=try PGNImporter.parse(Data("1. e4 *".utf8))[0],current=try PGNImporter.parse(Data("1. d4 *".utf8))[0]
        try store.save(future,cursor:0,branches:[])
        let bytes=try JSONSerialization.data(withJSONObject:["schemaVersion":2,"payload":"future"]);try bytes.write(to:store.documentURL(future.id),options:.atomic)
        XCTAssertTrue(try store.list().isEmpty);try store.save(current,cursor:1,branches:[])
        XCTAssertEqual(try store.list().map(\.id),[current.id]);XCTAssertThrowsError(try store.save(future,cursor:0,branches:[]))
        try store.delete(current.id);XCTAssertTrue(try store.list().isEmpty);XCTAssertEqual(try Data(contentsOf:store.documentURL(future.id)),bytes)
    }
    func testFutureMetadataPreservedWhileCurrentDocumentRemainsWritable()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let d=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],store=ReviewStore(directory:directory)
        try store.save(d,cursor:0,branches:[])
        let future=try JSONSerialization.data(withJSONObject:["schemaVersion":2,"future":"metadata"]),cursor=directory.appendingPathComponent(d.id.uuidString+".cursor.json"),index=directory.appendingPathComponent("index.json")
        try future.write(to:cursor,options:.atomic);try future.write(to:index,options:.atomic)
        try store.save(d,cursor:2,branches:[])
        XCTAssertEqual(try Data(contentsOf:cursor),future);XCTAssertEqual(try Data(contentsOf:index),future)
        let fresh=ReviewStore(directory:directory);XCTAssertEqual(try fresh.list().count,1);XCTAssertEqual(try fresh.load(d.id).cursor,2)
        XCTAssertEqual(try Data(contentsOf:index),future)
    }
    func testQuarantineFilesCountTowardLibraryQuota()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let quarantine=directory.appendingPathComponent("Quarantine");try FileManager.default.createDirectory(at:quarantine,withIntermediateDirectories:true)
        let large=quarantine.appendingPathComponent("retained-corrupt.json");FileManager.default.createFile(atPath:large.path,contents:Data())
        let handle=try FileHandle(forWritingTo:large);try handle.truncate(atOffset:UInt64(ReviewPolicy.maximumLibraryBytes));try handle.close()
        let store=ReviewStore(directory:directory),d=try PGNImporter.parse(Data("1. e4 *".utf8))[0]
        XCTAssertThrowsError(try store.save(d,cursor:0,branches:[]))
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.documentURL(d.id).path))
    }
    func testSerialWriterFlushKeepsLatestAfterBlockedOlderSave()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let d=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
        var blocked=false
        let store=ReviewStore(directory:directory,atomicWriter:{data,url in
            if url.lastPathComponent==d.id.uuidString+".json" && !blocked{blocked=true;entered.signal();_ = release.wait(timeout:.now()+3)}
            try data.write(to:url,options:.atomic)
        }),writer=ReviewSaveCoordinator(store:store)
        writer.save(d,cursor:0,branches:[]){_ in}
        XCTAssertEqual(entered.wait(timeout:.now()+2),.success)
        writer.save(d,cursor:1,branches:[]){_ in};writer.save(d,cursor:2,branches:[]){_ in}
        let done=expectation(description:"Synchronous quit flush completes after older in-flight save")
        DispatchQueue.global().async{do{_ = try writer.flush(d,cursor:2,branches:[])}catch{XCTFail("Flush failed")};done.fulfill()}
        release.signal();wait(for:[done],timeout:4)
        XCTAssertEqual(try ReviewStore(directory:directory).load(d.id).cursor,2)
    }
    @MainActor func testSynchronousFlushPerformsWritesOffMainThread()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let d=try PGNImporter.parse(Data("1. e4 *".utf8))[0]
        let store=ReviewStore(directory:directory,atomicWriter:{data,url in XCTAssertFalse(Thread.isMainThread);try data.write(to:url,options:.atomic)})
        _ = try ReviewSaveCoordinator(store:store).flush(d,cursor:1,branches:[])
        XCTAssertEqual(try ReviewStore(directory:directory).load(d.id).cursor,1)
    }
    func testDeleteRemovesRecordAndCursorButKeepsOtherReviews()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let store=ReviewStore(directory:directory),first=try PGNImporter.parse(Data("1. e4 *".utf8))[0],second=try PGNImporter.parse(Data("1. d4 *".utf8))[0]
        try store.save(first,cursor:1,branches:[]);try store.save(second,cursor:1,branches:[])
        try store.delete(first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.documentURL(first.id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent(first.id.uuidString+".cursor.json").path))
        XCTAssertEqual(try ReviewStore(directory:directory).list().map(\.id),[second.id])
    }
    func testDeleteRollsBackWhenIndexWriteFails()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        var fail=false
        let store=ReviewStore(directory:directory,atomicWriter:{data,url in
            if fail && url.lastPathComponent=="index.json"{throw CocoaError(.fileWriteNoPermission)}
            try data.write(to:url,options:.atomic)
        }),document=try PGNImporter.parse(Data("1. e4 *".utf8))[0]
        try store.save(document,cursor:1,branches:[])
        let original=try Data(contentsOf:store.documentURL(document.id))
        fail=true;XCTAssertThrowsError(try store.delete(document.id));fail=false
        XCTAssertEqual(try Data(contentsOf:store.documentURL(document.id)),original)
        XCTAssertEqual(try ReviewStore(directory:directory).load(document.id).cursor,1)
        XCTAssertEqual(try store.list().map(\.id),[document.id])
    }
    func testCoordinatorDeletionCannotBeRecreatedByLateAutosave()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:directory)}
        let store=ReviewStore(directory:directory),writer=ReviewSaveCoordinator(store:store)
        let document=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0]
        _ = try writer.flush(document,cursor:0,branches:[])
        for cursor in 0...2{writer.save(document,cursor:cursor,branches:[]){_ in}}
        XCTAssertTrue(try writer.delete(document.id).isEmpty)
        let rejected=expectation(description:"Late autosave rejected")
        writer.save(document,cursor:2,branches:[]){result in
            if case .success=result{XCTFail("Deleted review was recreated")};rejected.fulfill()
        }
        wait(for:[rejected],timeout:2)
        XCTAssertThrowsError(try writer.flush(document,cursor:2,branches:[]))
        XCTAssertTrue(try ReviewStore(directory:directory).list().isEmpty)
        // Undo of the deletion brings the record back and lets its saves through again.
        XCTAssertEqual(try writer.restore(document.id).map(\.id),[document.id])
        XCTAssertEqual(try writer.flush(document,cursor:2,branches:[]).map(\.id),[document.id])
    }
    /// R-10: an index written under an older title rule is rebuilt once, so saved reviews show the current titles.
    func testIndexFromAnOlderTitleRuleIsRebuilt()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let document=try PGNImporter.parse(Data("[Event \"London\"]\n[Round \"2\"]\n[White \"Alice\"]\n[Black \"Bob\"]\n\n1. e4 *".utf8))[0]
        try ReviewStore(directory:directory).save(document,cursor:0,branches:[])
        let file=directory.appendingPathComponent("index.json")
        var index=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any]);XCTAssertNotNil(index["titleRule"])
        var entries=try XCTUnwrap(index["entries"] as? [[String:Any]]);entries[0]["title"]="London";index["entries"]=entries;index["titleRule"]=nil
        try JSONSerialization.data(withJSONObject:index).write(to:file)
        XCTAssertEqual(try ReviewStore(directory:directory).list().map(\.title),["Alice – Bob · Round 2"])
        XCTAssertNotNil(try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])["titleRule"],"the rebuilt index records its rule")
    }
    private func trash(_ directory:URL,_ id:UUID)->URL {directory.appendingPathComponent("Trash").appendingPathComponent(id.uuidString)}
    /// R-12: a deleted review goes to the library's Trash and can be put back with its position and ideas.
    func testDeletedReviewMovesToTrashAndRestores()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let store=ReviewStore(directory:directory),first=try PGNImporter.parse(Data("1. e4 e5 *".utf8))[0],second=try PGNImporter.parse(Data("1. d4 *".utf8))[0]
        var branch=ReviewBranch(root:first.mainline[1]);branch.moves=["g1f3"]
        try store.save(first,cursor:2,branches:[branch]);try store.save(second,cursor:1,branches:[])
        try store.delete(first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath:store.documentURL(first.id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:trash(directory,first.id).appendingPathComponent(first.id.uuidString+".json").path))
        XCTAssertEqual(try store.list().map(\.id),[second.id])
        let reopened=ReviewStore(directory:directory)
        try reopened.restore(first.id)
        XCTAssertEqual(Set(try reopened.list().map(\.id)),[first.id,second.id]);XCTAssertEqual(Set(try ReviewStore(directory:directory).list().map(\.id)),[first.id,second.id])
        let saved=try reopened.load(first.id);XCTAssertEqual(saved.cursor,2);XCTAssertEqual(saved.branches,[branch])
        XCTAssertFalse(FileManager.default.fileExists(atPath:trash(directory,first.id).path),"a restored review leaves the Trash")
        XCTAssertThrowsError(try reopened.restore(first.id),"a review not in the Trash cannot be restored")
        // Deleted again, it replaces its earlier copy in the Trash.
        try reopened.delete(first.id);try reopened.delete(second.id);XCTAssertTrue(try reopened.list().isEmpty)
        try reopened.restore(first.id);XCTAssertEqual(try reopened.list().map(\.id),[first.id])
    }
    /// R-12: the Trash keeps a deleted review for 30 days, and gives way first when the library needs room.
    func testTrashIsPurgedAfterThirtyDaysAndWhenTheLibraryIsFull()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:directory)}
        let store=ReviewStore(directory:directory),old=try PGNImporter.parse(Data("1. e4 *".utf8))[0],recent=try PGNImporter.parse(Data("1. d4 *".utf8))[0]
        try store.save(old,cursor:1,branches:[]);try store.save(recent,cursor:1,branches:[]);try store.delete(old.id);try store.delete(recent.id)
        try FileManager.default.setAttributes([.creationDate:Date().addingTimeInterval(-31*24*3600)],ofItemAtPath:trash(directory,old.id).path)
        // Each review that leaves the Trash for good is named, so its engine analysis can go with it.
        let reopened=ReviewStore(directory:directory);var purged:[UUID]=[];reopened.onPurge={purged.append($0)};XCTAssertTrue(try reopened.list().isEmpty)
        XCTAssertEqual(purged,[old.id],"only the expired deletion is purged")
        XCTAssertFalse(FileManager.default.fileExists(atPath:trash(directory,old.id).path),"a review deleted 31 days ago is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath:trash(directory,recent.id).path))
        // A full library empties the Trash, oldest first, before refusing a save.
        let large=trash(directory,recent.id).appendingPathComponent("padding");FileManager.default.createFile(atPath:large.path,contents:Data())
        let handle=try FileHandle(forWritingTo:large);try handle.truncate(atOffset:UInt64(ReviewPolicy.maximumLibraryBytes));try handle.close()
        let next=try PGNImporter.parse(Data("1. c4 *".utf8))[0]
        try reopened.save(next,cursor:1,branches:[]);XCTAssertEqual(try reopened.list().map(\.id),[next.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath:trash(directory,recent.id).path))
        XCTAssertEqual(purged,[old.id,recent.id],"a deletion purged for room is named too")
        // Deleting a record again replaces its Trash copy: it is still in the Trash, so nothing is purged.
        try reopened.delete(next.id);try reopened.save(next,cursor:1,branches:[]);try reopened.delete(next.id)
        XCTAssertEqual(purged,[old.id,recent.id])
    }
}
