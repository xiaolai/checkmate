import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateApplication

/// The saved-review library's running byte total (R-28), saved-review names and metadata (R-11), collection names and
/// library sorting (R-21), and the annotated PGN export (R-13).
final class LibraryOrganisationTests:XCTestCase {
    private var folder:URL!
    override func setUpWithError() throws {folder=FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString)")}
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:folder)}
    private func game(_ text:String)throws -> GameDocument {try PGNImporter.parse(Data(text.utf8))[0]}
    private func branch(_ root:Int,_ moves:[String])->ReviewBranch {var branch=ReviewBranch(root:root);branch.moves=moves;return branch}
    /// What a full directory walk finds outside the Trash: the figure the running total must always equal.
    private func scanned(_ directory:URL)throws -> Int {
        var total=0;let enumerator=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.isRegularFileKey,.fileSizeKey])
        while let file=enumerator?.nextObject() as? URL {if enumerator?.level==1,file.lastPathComponent=="Trash"{enumerator?.skipDescendants();continue};let values=try file.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]);if values.isRegularFile==true{total+=values.fileSize ?? 0}}
        return total
    }

    // MARK: R-28

    func testSavesKeepARunningTotalInsteadOfScanningTheLibrary()throws {
        let store=ReviewStore(directory:folder),first=try game("[White \"A\"]\n[Black \"B\"]\n\n1. e4 e5 *"),second=try game("1. d4 d5 *")
        try store.save(first,cursor:1,branches:[]);XCTAssertEqual(store.measurements,1,"the first full save measures the library once")
        try store.save(second,cursor:1,branches:[]);try store.save(first,cursor:2,branches:[]);try store.save(first,cursor:2,branches:[branch(1,["c7c5"])])
        XCTAssertEqual(try store.libraryBytes(),try scanned(folder));XCTAssertEqual(store.measurements,1,"later saves adjust the total, never walk the folder again")
        // Deleting moves a record into the Trash, which the total leaves out; restoring brings it back.
        try store.delete(second.id);XCTAssertEqual(try store.libraryBytes(),try scanned(folder))
        try store.restore(second.id);XCTAssertEqual(try store.libraryBytes(),try scanned(folder))
        try store.delete(first.id);try store.save(second,cursor:2,branches:[]);XCTAssertEqual(try store.libraryBytes(),try scanned(folder))
        try store.rename(second.id,to:"A long and memorable name");XCTAssertEqual(try store.libraryBytes(),try scanned(folder))
        XCTAssertEqual(store.measurements,1)
    }

    func testAFileAddedBehindTheStoresBackIsMeasuredBeforeTheNextSave()throws {
        let store=ReviewStore(directory:folder),first=try game("1. e4 *"),second=try game("1. d4 *")
        try store.save(first,cursor:1,branches:[])
        let filler=folder.appendingPathComponent("filler.bin");XCTAssertTrue(FileManager.default.createFile(atPath:filler.path,contents:nil))
        let handle=try FileHandle(forWritingTo:filler);try handle.truncate(atOffset:UInt64(ReviewPolicy.maximumLibraryBytes));try handle.close()
        XCTAssertThrowsError(try store.save(second,cursor:1,branches:[]),"a stale total would let this save pass the quota")
        XCTAssertEqual(store.measurements,2);try FileManager.default.removeItem(at:filler)
        try store.save(second,cursor:1,branches:[]);XCTAssertEqual(try store.libraryBytes(),try scanned(folder))
        // Another store writing to the same folder is noticed the same way.
        let other=ReviewStore(directory:folder);try other.save(try game("1. c4 *"),cursor:1,branches:[])
        XCTAssertEqual(try store.libraryBytes(),try scanned(folder))
    }
    /// A file edited in place leaves the folder's own date alone; its own size and date still show the total is stale.
    func testAFileEditedInPlaceIsMeasuredBeforeTheNextSave()throws {
        let store=ReviewStore(directory:folder),first=try game("1. e4 *"),second=try game("1. d4 *")
        try store.save(first,cursor:1,branches:[]);XCTAssertEqual(store.measurements,1)
        let handle=try FileHandle(forWritingTo:store.documentURL(first.id));try handle.truncate(atOffset:UInt64(ReviewPolicy.maximumLibraryBytes));try handle.close()
        XCTAssertThrowsError(try store.save(second,cursor:1,branches:[]),"a stale total would let this save pass the quota")
        XCTAssertEqual(store.measurements,2);XCTAssertEqual(try store.libraryBytes(),try scanned(folder))
    }
    /// A cursor save and the review list look at their own files and the folder's dates, a fixed handful whatever the
    /// library's size, and a cursor file edited in place is still noticed by the next save that touches it.
    func testACursorSaveLooksOnlyAtItsOwnFiles()throws {
        let store=ReviewStore(directory:folder),games=try (1...40).map{try game("[White \"W\($0)\"]\n[Black \"B\"]\n\n1. e4 e5 *")}
        for document in games{try store.save(document,cursor:1,branches:[])}
        var before=store.looked;XCTAssertEqual(try store.list().count,games.count)
        XCTAssertLessThanOrEqual(store.looked-before,2,"listing the reviews reads the folder's date, not each review")
        before=store.looked;try store.save(games[0],cursor:2,branches:[])
        XCTAssertLessThanOrEqual(store.looked-before,16,"a cursor save stats a few files, not each of the library's \(games.count*2)")
        XCTAssertEqual(store.measurements,1);XCTAssertEqual(try store.libraryBytes(),try scanned(folder))
        // Spaces added to a cursor file keep it readable but change its size without touching the folder's date.
        let cursor=folder.appendingPathComponent(games[1].id.uuidString+".cursor.json"),handle=try FileHandle(forWritingTo:cursor)
        try handle.seekToEnd();try handle.write(contentsOf:Data(repeating:0x20,count:100));try handle.close()
        try store.save(games[1],cursor:2,branches:[]);XCTAssertEqual(try store.libraryBytes(),try scanned(folder));XCTAssertEqual(store.measurements,2)
    }
    /// Writes a review's record as another program would, in place (the folder's date stays put) or by replacing it
    /// whole (written beside it and renamed over it, which changes the folder's date), under a new name.
    private func rename(_ url:URL,to name:String,inPlace:Bool)throws {
        var saved=try JSONDecoder().decode(SavedReview.self,from:Data(contentsOf:url));saved.name=name;let data=try JSONEncoder().encode(saved)
        if inPlace{let handle=try FileHandle(forWritingTo:url);try handle.truncate(atOffset:0);try handle.write(contentsOf:data);try handle.close()}else{try data.write(to:url,options:.atomic)}
    }
    /// A review rewritten in place by another program and then opened shows its new title from then on: after the
    /// store's own saves and deletions, and to a store that reads the saved index afresh.
    func testAReviewRewrittenInPlaceAndThenOpenedIsListedWithItsNewTitle()throws {
        let store=ReviewStore(directory:folder),first=try game("[White \"Old\"]\n[Black \"B\"]\n\n1. e4 e5 *"),second=try game("1. d4 d5 *")
        try store.save(first,cursor:1,branches:[]);try store.save(second,cursor:1,branches:[]);XCTAssertEqual(try store.list().count,2)
        try rename(store.documentURL(first.id),to:"Renamed elsewhere",inPlace:true)
        XCTAssertEqual(try store.load(first.id).name,"Renamed elsewhere")
        try store.save(second,cursor:2,branches:[]);XCTAssertEqual(try store.list().first{$0.id==first.id}?.title,"Renamed elsewhere")
        try store.delete(second.id);XCTAssertEqual(try store.list().map(\.title),["Renamed elsewhere"])
        XCTAssertEqual(try ReviewStore(directory:folder).list().map(\.title),["Renamed elsewhere"],"the saved index holds the new title")
    }
    /// A review replaced whole by another program changes the folder's date, so the same store lists its new title,
    /// also after its own next change.
    func testAReviewReplacedWholeByAnotherProgramIsListedWithItsNewTitle()throws {
        let store=ReviewStore(directory:folder),first=try game("[White \"Old\"]\n[Black \"B\"]\n\n1. e4 e5 *"),second=try game("1. d4 d5 *")
        try store.save(first,cursor:1,branches:[]);try store.save(second,cursor:1,branches:[]);XCTAssertEqual(try store.list().count,2)
        try rename(store.documentURL(first.id),to:"Replaced elsewhere",inPlace:false)
        try store.save(second,cursor:2,branches:[]);XCTAssertEqual(try store.list().first{$0.id==first.id}?.title,"Replaced elsewhere")
        XCTAssertEqual(try store.libraryBytes(),try scanned(folder))
    }
    /// A file another program adds between the store's look at the folder and its own change is not taken for part of
    /// that change: the list and the byte total still find it.
    func testAFileAddedDuringTheStoresOwnChangeIsNotTakenForPartOfIt()throws {
        let store=ReviewStore(directory:folder),games=try (1...3).map{try game("[White \"W\($0)\"]\n[Black \"B\"]\n\n1. e4 e5 *")}
        for document in games{try store.save(document,cursor:1,branches:[])};XCTAssertEqual(try store.list().count,3)
        let intruder=try game("[White \"Intruder\"]\n[Black \"B\"]\n\n1. c4 *"),target=store.documentURL(intruder.id)
        let data=try JSONEncoder().encode(SavedReview(schemaVersion:1,document:intruder,cursor:0,branches:[],updatedAt:Date()));var added=false
        store.beforeChange={guard !added else{return};added=true;do{try data.write(to:target)}catch{XCTFail("the other program could not write: \(error)")}}
        try store.save(games[0],cursor:2,branches:[]);XCTAssertTrue(added,"the other program wrote during the store's change")
        XCTAssertEqual(try store.list().map(\.id).sorted{$0.uuidString<$1.uuidString},(games+[intruder]).map(\.id).sorted{$0.uuidString<$1.uuidString})
        XCTAssertEqual(try store.libraryBytes(),try scanned(folder))
    }

    // MARK: R-11

    func testSavedReviewsCarryTheirGameDetailsAndKeepARenameThroughSavesDeletionAndRebuilds()throws {
        let store=ReviewStore(directory:folder),document=try game("[Event \"Club Championship\"]\n[Date \"2024.03.09\"]\n[White \"Ada\"]\n[Black \"Bo\"]\n\n1. e4 e5 *")
        try store.save(document,cursor:1,branches:[])
        var entry=try XCTUnwrap(try store.list().first)
        XCTAssertEqual(entry.title,"Ada – Bo");XCTAssertNil(entry.name);XCTAssertEqual(entry.white,"Ada");XCTAssertEqual(entry.black,"Bo");XCTAssertEqual(entry.event,"Club Championship");XCTAssertEqual(entry.date,"2024.03.09")
        let saved=entry.updatedAt
        try store.rename(document.id,to:"  My first win\n")
        entry=try XCTUnwrap(try store.list().first);XCTAssertEqual(entry.title,"My first win");XCTAssertEqual(entry.name,"My first win");XCTAssertEqual(entry.updatedAt,saved,"a rename does not move the review up the recent list")
        // Cursor saves, full saves, deletion and its undo, and a fresh store keep the name.
        try store.save(document,cursor:2,branches:[]);XCTAssertEqual(try store.list().first?.title,"My first win")
        try store.save(document,cursor:2,branches:[branch(1,["c7c5"])]);XCTAssertEqual(try store.list().first?.title,"My first win")
        try store.delete(document.id);try store.restore(document.id);XCTAssertEqual(try store.list().first?.title,"My first win")
        XCTAssertEqual(try ReviewStore(directory:folder).list().first?.title,"My first win")
        try FileManager.default.removeItem(at:folder.appendingPathComponent("index.json"))
        XCTAssertEqual(try ReviewStore(directory:folder).list().first?.name,"My first win","a rebuilt index reads the name from the record")
        // An empty name gives the review its game's title back.
        try store.rename(document.id,to:"   ");entry=try XCTUnwrap(try store.list().first);XCTAssertEqual(entry.title,"Ada – Bo");XCTAssertNil(entry.name)
        XCTAssertThrowsError(try store.rename(UUID(),to:"Nothing"))
    }

    func testAnIndexWrittenBeforeGameDetailsIsRebuiltOnceAndOldRecordsStillOpen()throws {
        let store=ReviewStore(directory:folder),document=try game("[White \"Ada\"]\n[Black \"Bo\"]\n\n1. e4 *");try store.save(document,cursor:1,branches:[])
        // An index from the previous rule has no details; the record itself is the older format, without a name.
        let index=folder.appendingPathComponent("index.json"),stamps=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:index)) as? [String:Any])["stamps"]
        let old:[String:Any]=["schemaVersion":1,"titleRule":1,"stamps":stamps as Any,"entries":[["id":document.id.uuidString,"title":"Ada – Bo","result":"*","updatedAt":0]]]
        try JSONSerialization.data(withJSONObject:old).write(to:index)
        let entry=try XCTUnwrap(try ReviewStore(directory:folder).list().first);XCTAssertEqual(entry.white,"Ada");XCTAssertEqual(entry.black,"Bo")
        var record=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:store.documentURL(document.id))) as? [String:Any]);XCTAssertNil(record["name"]);record["futureField"]="kept"
        try JSONSerialization.data(withJSONObject:record).write(to:store.documentURL(document.id))
        XCTAssertEqual(try ReviewStore(directory:folder).load(document.id).document.id,document.id)
    }

    // MARK: R-21

    func testACollectionRenameIsStoredInItsNameFileAndSurvivesARebuiltIndex()throws {
        let library=folder.appendingPathComponent("Library"),store=GameCollectionStore(directory:library)
        let collection=try store.importCollection(Data("[Event \"Open\"]\n\n1. e4 *\n\n[Event \"Open\"]\n\n1. d4 *".utf8),name:"two.pgn")
        try store.rename(collection.sha256,to:" Club games ")
        XCTAssertEqual(try store.load().collections.first?.name,"Club games")
        XCTAssertEqual(try String(contentsOf:library.appendingPathComponent(collection.sha256+".name"),encoding:.utf8),"Club games")
        try FileManager.default.removeItem(at:library.appendingPathComponent(collection.sha256+".index.json"))
        XCTAssertEqual(try GameCollectionStore(directory:library).load().collections.first?.name,"Club games")
        XCTAssertThrowsError(try store.rename(collection.sha256,to:"  "),"a collection always has a name")
        XCTAssertThrowsError(try store.rename(String(repeating:"0",count:64),to:"Missing"))
    }

    private func collection(_ games:[(white:String,black:String,event:String,date:String)])throws -> CollectionIndex {
        let text=games.map{"[Event \"\($0.event)\"]\n[Date \"\($0.date)\"]\n[White \"\($0.white)\"]\n[Black \"\($0.black)\"]\n\n1. e4 *"}.joined(separator:"\n\n")
        return try GameCollectionStore(directory:folder.appendingPathComponent("Library")).importCollection(Data(text.utf8),name:"games.pgn")
    }

    func testLibraryRowsSortByPlayersDateOrEventWithinEachSection()throws {
        let games=try collection([("Carl","Dana","Spring Open","2021.05.01"),("Abe","Zoe","Autumn Cup","2023.10.02"),("Bea","Yan","Winter Open","2019.01.03")])
        let catalog=LibraryCatalog(library:nil,collections:[games])
        func titles(_ sort:LibrarySort)->[String] {catalog.sections(scope:.myGames,query:"",sort:sort).flatMap{$0.rows.map(\.title)}}
        XCTAssertEqual(titles(.standard),["Carl – Dana","Abe – Zoe","Bea – Yan"],"the default keeps the file's order")
        XCTAssertEqual(titles(.players),["Abe – Zoe","Bea – Yan","Carl – Dana"])
        XCTAssertEqual(titles(.date),["Abe – Zoe","Carl – Dana","Bea – Yan"],"newest first")
        XCTAssertEqual(titles(.event),["Abe – Zoe","Carl – Dana","Bea – Yan"])
        XCTAssertEqual(LibrarySort.allCases.map(\.title),["Default Order","Players","Date","Event"])
    }

    func testSavedReviewsAreAScopeOfTheLibraryWithTheirDetails()throws {
        let earlier=ReviewIndexEntry(id:UUID(),title:"Ada – Bo",result:"1-0",updatedAt:Date(timeIntervalSince1970:1_000),white:"Ada",black:"Bo",event:"Club Championship",date:"2024.03.09")
        let later=ReviewIndexEntry(id:UUID(),title:"My best game",result:"*",updatedAt:Date(timeIntervalSince1970:2_000),name:"My best game",white:"Cy",black:"Di")
        let catalog=LibraryCatalog(library:nil,collections:[],saved:[later,earlier])
        let sections=catalog.sections(scope:.saved,query:"",sort:.standard)
        XCTAssertEqual(sections.map(\.kind),[.saved]);XCTAssertEqual(sections.first?.rows.map(\.title),["My best game","Ada – Bo"],"most recent first")
        XCTAssertEqual(sections.first?.rows.last?.source,.saved(earlier.id));XCTAssertEqual(sections.first?.rows.last?.details,"Club Championship · 2024")
        XCTAssertEqual(catalog.sections(scope:.saved,query:"club",sort:.standard).first?.rows.map(\.title),["Ada – Bo"],"search reads the game's details")
        XCTAssertEqual(catalog.sections(scope:.saved,query:"cy",sort:.standard).first?.rows.map(\.title),["My best game"])
        XCTAssertEqual(catalog.sections(scope:.saved,query:"",sort:.players).first?.rows.map(\.title),["Ada – Bo","My best game"])
        XCTAssertTrue(catalog.sections(scope:.all,query:"",sort:.standard).isEmpty,"saved reviews have their own scope, apart from the games to choose from")
        XCTAssertEqual(LibraryScope.saved.title,"Saved")
    }

    // MARK: R-13

    func testAnExportKeepsTheGameAsOneRecordWithImaginedLinesEvaluationsAndGlyphs()throws {
        let document=try game("[Event \"Club\"]\n[White \"Ada\"]\n[Black \"Bo\"]\n[Result \"1-0\"]\n\n{Start} 1. e4 $1 {best by test} e5 (1... c5 2. Nf3) 2. Nf3 Nc6 3. Bb5 1-0")
        let main=document.mainline,root=main[1]  // after 1... e5
        let branches=[branch(root,["g1f3","b8c6","f1c4"]),branch(root,["f1c4"]),branch(main.last!,["a7a6"]),branch(0,["c2c4"])]
        let evaluations:[Int:AnalysisScore]=[main[0]:AnalysisScore(kind:"cp",value:35),main[1]:AnalysisScore(kind:"cp",value:-120),main[2]:AnalysisScore(kind:"mate",value:-3)]
        let exported=try PGNExporter.withIdeas(document,branches:branches,evaluations:evaluations,grades:[main[0]:.mistake,main[1]:.blunder])
        let records=try PGNImporter.parse(exported);XCTAssertEqual(records.count,1,"imagined lines are variations of the game, not separate games")
        let back=records[0];XCTAssertEqual(back.result,"1-0");XCTAssertEqual(back.header("White"),"Ada");XCTAssertEqual(back.header("Event"),"Club")
        XCTAssertEqual(back.mainline.compactMap{back.nodes[$0].uci},document.mainline.compactMap{document.nodes[$0].uci},"the mainline is unchanged")
        func line(_ node:Int)->[String] {var moves:[String]=[],cursor=node;while let parent=back.nodes[cursor].parent{moves.append(back.nodes[cursor].uci!);cursor=parent};return moves.reversed()}
        let leaves=back.nodes.filter{$0.children.isEmpty}.map{line($0.id)}
        // A line from the game's last move varies that move: 3. Bb5 is repeated in a variation that goes on with 3... a6.
        for expected in [["e2e4","c7c5","g1f3"],["e2e4","e7e5","f1c4"],["e2e4","e7e5","g1f3","b8c6","f1c4"],["e2e4","e7e5","g1f3","b8c6","f1b5","a7a6"],["c2c4"]] {XCTAssertTrue(leaves.contains(expected),"missing line \(expected) in \(leaves)")}
        XCTAssertEqual(leaves.count,6,"the game and five lines: a line that repeats the game's moves adds only where it leaves them")
        let e4=back.nodes[back.mainline[0]],e5=back.nodes[back.mainline[1]],nf3=back.nodes[back.mainline[2]]
        XCTAssertEqual(e4.nags,[1],"the record's own glyph wins over a grade");XCTAssertTrue(e4.commentsAfter.contains("best by test"));XCTAssertTrue(e4.commentsAfter.contains("[%eval 0.35]"))
        XCTAssertEqual(e5.nags,[4]);XCTAssertTrue(e5.commentsAfter.contains("[%eval -1.20]"));XCTAssertTrue(nf3.commentsAfter.contains("[%eval #-3]"))
        XCTAssertEqual(back.nodes[0].commentsBefore,["Start"])
        // A second export of the read-back game reads back the same.
        let again=try PGNImporter.parse(PGNExporter.withIdeas(back,branches:[]))[0];XCTAssertEqual(again.nodes.map(\.uci),back.nodes.map(\.uci));XCTAssertEqual(again.nodes.map(\.nags),back.nodes.map(\.nags));XCTAssertEqual(again.nodes.map(\.commentsAfter),back.nodes.map(\.commentsAfter))
    }

    /// A comment may hold "}" (a ";" comment reads to the end of its line), which would end a "{…}" comment early: the
    /// export writes it as ")", so the comment and the moves after it read back intact.
    func testABraceInACommentCannotEndItsExportedComment()throws {
        let document=try game("1. e4 ; a } 2. d4 b\ne5 *")
        let exported=String(decoding:try PGNExporter.withIdeas(document,branches:[]),as:UTF8.self)
        XCTAssertTrue(exported.contains("{ a ) 2. d4 b}"),exported)
        let back=try PGNImporter.parse(Data(exported.utf8));XCTAssertEqual(back.count,1)
        XCTAssertEqual(back[0].mainline.compactMap{back[0].nodes[$0].uci},["e2e4","e7e5"],"the brace did not leak moves out of the comment")
        XCTAssertEqual(back[0].nodes[back[0].mainline[0]].commentsAfter,[" a ) 2. d4 b"],"the comment reads back as it was written, its brace aside")
    }
    func testAPositionExportsWithItsSetUpAndHeadersAreEscaped()throws {
        let position=try game("8/8/8/8/8/8/k7/4K2R w K - 0 1")
        let exported=String(decoding:try PGNExporter.withIdeas(position,branches:[branch(0,["h1h2"])]),as:UTF8.self)
        XCTAssertTrue(exported.contains("[SetUp \"1\"]"));XCTAssertTrue(exported.contains("[FEN \"8/8/8/8/8/8/k7/4K2R w K - 0 1\"]"))
        let back=try PGNImporter.parse(Data(exported.utf8));XCTAssertEqual(back.count,1);XCTAssertEqual(back[0].startingFEN,position.startingFEN);XCTAssertEqual(back[0].nodes.compactMap(\.uci),["h1h2"])
        let quoted=try game("[Event \"The \\\"Big\\\" One\"]\n\n1. e4 *");XCTAssertEqual(try PGNImporter.parse(PGNExporter.withIdeas(quoted,branches:[]))[0].header("Event"),"The \"Big\" One")
    }

    func testTheExportFileIsNamedAfterTheReview()throws {
        let document=try game("[White \"Ada\"]\n[Black \"Bo/Cy\"]\n\n1. e4 *")
        XCTAssertEqual(PGNExporter.fileName(document.title,pgn:true),"Ada – Bo-Cy.pgn")
        XCTAssertEqual(PGNExporter.fileName(":..\u{0}",pgn:true),"review.pgn","nothing usable left falls back to a plain name")
        XCTAssertEqual(PGNExporter.fileName(".hidden",pgn:false),"hidden.fen","never a hidden file")
        XCTAssertEqual(PGNExporter.fileName(String(repeating:"x",count:300),pgn:true).count,84)
    }
}
