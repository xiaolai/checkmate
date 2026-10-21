import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateApplication

/// Imported collections (plan Group C) and the library catalog's search and grouping (plan WI-15, WI-16).
final class GameCollectionsTests:XCTestCase {
    private var folder:URL!
    override func setUpWithError() throws {folder=FileManager.default.temporaryDirectory.appendingPathComponent("collections-\(UUID().uuidString)")}
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:folder)}
    private var library:URL {folder.appendingPathComponent("Library")}
    /// A valid record, an illegal one, a valid one with an escaped tag, a comment and a variation; then a lexically
    /// broken record and a final valid one.
    private let fixture="""
    [Event "First"]
    [White "Alpha"]
    [Black "Beta"]
    [Result "1-0"]

    1. e4 e5 2. Qh5 Nc6 3. Bc4 Nf6 4. Qxf7# 1-0

    [Event "Illegal"]
    [White "Gamma"]
    [Black "Delta"]
    [Result "0-1"]

    1. e4 e5 2. Ke3 Ke6 0-1

    [Event "Escaped \\"quoted\\" event"]
    [White "Réti, Richard"]
    [Black "Epsilon"]
    [Result "1/2-1/2"]
    [Opening "Réti Opening"]

    1. Nf3 {a comment} d5 (1... Nf6 2. c4) 2. c4 1/2-1/2

    [Event "Broken"]
    [White "Bad\\xescape"]

    1. d4 *

    [Event "Last"]
    [White "Zeta"]
    [Black "Eta"]
    [Result "*"]

    1. d4 d5 *
    """
    func testSplitReadsTagsByteRangesAndLexicalFailures() throws {
        let data=Data(fixture.utf8),store=GameCollectionStore(directory:library)
        let index=try store.importCollection(data,name:"fixture.pgn")
        XCTAssertEqual(index.records.map{$0.tags["Event"]},["First","Illegal","Escaped \"quoted\" event","Last"])
        XCTAssertEqual(index.unreadable,1,"The record whose header cannot be read is counted, not listed")
        XCTAssertEqual(index.records[2].tags["White"],"Réti, Richard")
        // Each range is exactly its record, from its first header to its result.
        let texts=try index.records.map{String(decoding:try store.data($0,in:index),as:UTF8.self)}
        XCTAssertTrue(texts[0].hasPrefix("[Event \"First\"]") && texts[0].hasSuffix("4. Qxf7# 1-0"))
        XCTAssertTrue(texts[2].contains("(1... Nf6 2. c4)") && texts[2].hasSuffix("1/2-1/2"))
        // A record is validated only when opened: valid, invalid, valid.
        XCTAssertEqual(try PGNImporter.parseReport(Data(texts[0].utf8),provenance:.collectionGame).documents.count,1)
        XCTAssertThrowsError(try PGNImporter.parseReport(Data(texts[1].utf8),provenance:.collectionGame))
        XCTAssertEqual(try PGNImporter.parseReport(Data(texts[2].utf8),provenance:.collectionGame).documents.first?.header("Event"),"Escaped \"quoted\" event")
        XCTAssertEqual(try PGNImporter.parseReport(Data(texts[3].utf8),provenance:.collectionGame).documents.count,1)
    }
    func testByteRangesHoldInLatin1AndWithAByteOrderMark() throws {
        let latin=try XCTUnwrap("[White \"Réti\"]\n[Result \"*\"]\n\n1. Nf3 *\n\n[White \"Zeta\"]\n[Result \"*\"]\n\n1. e4 *\n".data(using:.isoLatin1))
        let bom=Data([0xEF,0xBB,0xBF])+Data("[White \"Réti\"]\n[Result \"*\"]\n\n1. Nf3 *\n\n[White \"Zeta\"]\n[Result \"*\"]\n\n1. e4 *\n".utf8)
        for (number,data) in [latin,bom].enumerated() {
            let store=GameCollectionStore(directory:library.appendingPathComponent("\(number)")),index=try store.importCollection(data,name:"x")
            XCTAssertEqual(index.records.map{$0.tags["White"]},["Réti","Zeta"])
            XCTAssertEqual(try store.data(index.records[1],in:index),Data("[White \"Zeta\"]\n[Result \"*\"]\n\n1. e4 *".utf8))
        }
    }
    func testACorruptedRangeFailsWhenOpened() throws {
        let store=GameCollectionStore(directory:library),index=try store.importCollection(Data(fixture.utf8),name:"fixture.pgn")
        let moved=CollectionRecord(offset:index.records[0].offset+1,length:index.records[0].length,sha256:index.records[0].sha256,tags:[:])
        XCTAssertThrowsError(try store.data(moved,in:index))
        XCTAssertNoThrow(try store.data(index.records[0],in:index))
    }
    func testDuplicateContentIsStoredOnceAndRemovalDeletesBothFiles() throws {
        let store=GameCollectionStore(directory:library),data=Data(fixture.utf8)
        let first=try store.importCollection(data,name:"a.pgn"),second=try store.importCollection(data,name:"b.pgn")
        XCTAssertEqual(first,second)
        // `.lock` is the folder's own lock file, never a collection.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:library.path).sorted(),[".lock",first.sha256+".index.json",first.sha256+".name",first.sha256+".pgn"])
        XCTAssertEqual(try store.load().collections.map(\.sha256),[first.sha256])
        try store.remove(first.sha256)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:library.path),[".lock"])
        XCTAssertEqual(try store.load().collections,[])
    }
    func testQuotaIsTheLibrarysOwn() throws {
        let data=Data(fixture.utf8),store=GameCollectionStore(directory:library,quotaBytes:data.count+100)
        XCTAssertThrowsError(try store.importCollection(data,name:"a.pgn")){XCTAssertTrue(userFacingMessage($0,fallback:"").contains("full"))}
        XCTAssertEqual(GameCollectionStore.quotaBytes,256*1024*1024);XCTAssertEqual(ReviewPolicy.maximumLibraryBytes,512*1024*1024)
        // The reviews' folder is not counted: a large file there leaves the collection quota untouched.
        let reviews=folder.appendingPathComponent("Reviews");try FileManager.default.createDirectory(at:reviews,withIntermediateDirectories:true)
        try Data(count:4096).write(to:reviews.appendingPathComponent("big.json"))
        let roomy=GameCollectionStore(directory:library,quotaBytes:64*1024);XCTAssertNoThrow(try roomy.importCollection(data,name:"a.pgn"))
        XCTAssertLessThan(roomy.usedBytes(),data.count*3)
    }
    func testTooManyRecordsIsRefused() throws {
        let data=Data(String(repeating:"1. e4 *\n",count:GameCollectionStore.maximumRecords+1).utf8)
        XCTAssertThrowsError(try GameCollectionStore(directory:library).importCollection(data,name:"many.pgn"))
        XCTAssertEqual(try GameCollectionStore(directory:library).importCollection(Data(String(repeating:"1. e4 *\n",count:3).utf8),name:"few.pgn").records.count,3)
    }
    func testLoadRebuildsAStaleIndexAndRemovesStrayTemporaryFiles() throws {
        let store=GameCollectionStore(directory:library),index=try store.importCollection(Data(fixture.utf8),name:"fixture.pgn")
        let indexURL=library.appendingPathComponent(index.sha256+".index.json"),stray=library.appendingPathComponent(".\(index.sha256).pgn.1234.tmp")
        try Data("partial".utf8).write(to:stray)
        for damage in [Data("not json".utf8),Data(#"{"schemaVersion":0}"#.utf8),nil] {
            if let damage{try damage.write(to:indexURL)}else{try FileManager.default.removeItem(at:indexURL)}
            let loaded=try store.load()
            XCTAssertEqual(loaded.collections.map(\.records),[index.records]);XCTAssertEqual(loaded.broken,[])
            XCTAssertNoThrow(try JSONDecoder().decode(CollectionIndex.self,from:Data(contentsOf:indexURL)),"The index was rewritten")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:stray.path))
        // A damaged collection file is shown as broken, beside the others, not hidden.
        let other=try store.importCollection(Data("[White \"Zeta\"]\n\n1. e4 *\n".utf8),name:"other.pgn")
        try Data("changed".utf8).write(to:library.appendingPathComponent(index.sha256+".pgn"))
        let loaded=try store.load()
        XCTAssertEqual(loaded.collections.map(\.sha256),[other.sha256]);XCTAssertEqual(loaded.broken.map(\.id),[index.sha256])
    }
    func testRemovalCancelsAnImportOfThatCollectionInFlight() throws {
        let store=GameCollectionStore(directory:library),data=Data(fixture.utf8),sha=reviewHash(data)
        var removed=false
        XCTAssertThrowsError(try store.importCollection(data,name:"a.pgn",cancelled:{if !removed{removed=true;try? store.remove(sha)};return false})){error in guard case .cancelled? = error as? CheckmateError else{return XCTFail("\(error)")}}
        XCTAssertTrue(removed);XCTAssertFalse(FileManager.default.fileExists(atPath:library.appendingPathComponent(sha+".pgn").path))
        XCTAssertNoThrow(try store.importCollection(data,name:"a.pgn"),"A later import of the same content proceeds")
    }
    /// MCP sees saved reviews only: importing a collection changes nothing it lists; saving one review from it adds one.
    func testCollectionsStayOutOfTheReviewList() throws {
        let reviews=ReviewStore(directory:folder.appendingPathComponent("Reviews")),store=GameCollectionStore(directory:library)
        XCTAssertEqual(try reviews.list().count,0)
        let index=try store.importCollection(Data(fixture.utf8),name:"fixture.pgn")
        XCTAssertEqual(try reviews.list().count,0)
        let document=try XCTUnwrap(PGNImporter.parseReport(try store.data(index.records[0],in:index),provenance:.collectionGame).documents.first)
        try reviews.save(document,cursor:0,branches:[])
        XCTAssertEqual(try reviews.list().map(\.id),[document.id])
        // The saved review holds its own bytes: removing the collection leaves it fully readable.
        try store.remove(index.sha256)
        XCTAssertEqual(try reviews.load(document.id).document.original,document.original)
    }
    // MARK: Catalog
    func testSearchFoldsCaseAndDiacriticsOverPlayersEventYearRoundAndOpening() throws {
        let store=GameCollectionStore(directory:library),index=try store.importCollection(Data(fixture.utf8),name:"fixture.pgn")
        let catalog=LibraryCatalog(library:try GameLibrary.load(),collections:[index])
        func ids(_ query:String,_ scope:LibraryScope = .all)->[String] {catalog.sections(scope:scope,query:query).flatMap(\.rows).map(\.id)}
        XCTAssertEqual(ids("reti",.myGames),["collection:\(index.sha256):2"],"Reti finds Réti")
        XCTAssertEqual(ids("RÉTI OPENING",.myGames),["collection:\(index.sha256):2"])
        XCTAssertTrue(ids("grunfeld").contains("library:wch-1963-5"),"Grunfeld finds Grünfeld")
        XCTAssertEqual(Set(ids("1972")),["library:wch-1972-1","library:wch-1972-3","library:wch-1972-6","library:wch-1972-13"])
        XCTAssertTrue(ids("fischer spassky game 6").contains("library:wch-1972-6"));XCTAssertFalse(ids("fischer spassky game 6").contains("library:wch-1972-3"))
        XCTAssertEqual(ids("tiebreak carlsen karjakin"),["library:wch-2016-tiebreak-4"])
        XCTAssertEqual(ids("no such game anywhere"),[])
    }
    func testGroupingAndOrdering() throws {
        let store=GameCollectionStore(directory:library),index=try store.importCollection(Data(fixture.utf8),name:"fixture.pgn")
        let broken=BrokenCollection(id:String(repeating:"a",count:64),name:"Collection",error:"damaged")
        let catalog=LibraryCatalog(library:try GameLibrary.load(),collections:[index],broken:[broken])
        let all=catalog.sections(scope:.all,query:"")
        XCTAssertEqual(all.first?.id,"event:wch-2024");XCTAssertEqual(all.first(where:{$0.kind == .event})?.rows.map(\.id),["library:wch-2024-1","library:wch-2024-3","library:wch-2024-11","library:wch-2024-14"])
        let events=all.filter{$0.kind == .event}.map(\.id);XCTAssertEqual(events.count,53);XCTAssertEqual(events.last,"event:wch-1886")
        XCTAssertEqual(all.map(\.id).suffix(3),["classics","collection:"+index.sha256,"collection:"+broken.id])
        XCTAssertEqual(catalog.sections(scope:.classics,query:"").map(\.id),["classics"])
        XCTAssertEqual(catalog.sections(scope:.worldChampionships,query:"").count,53)
        XCTAssertEqual(catalog.sections(scope:.myGames,query:"").map(\.id),["collection:"+index.sha256,"collection:"+broken.id])
        // A broken collection keeps its own section while searching, without hiding the others.
        XCTAssertEqual(catalog.sections(scope:.myGames,query:"zeta").map(\.id),["collection:"+index.sha256,"collection:"+broken.id])
        let row=try XCTUnwrap(catalog.sections(scope:.all,query:"zukertort steinitz game 1").first?.rows.first)
        // Under its event a row shows the players and game, then only the facts; the full title is its label.
        XCTAssertEqual(row.title,"Zukertort – Steinitz, Game 1");XCTAssertEqual(row.details,"")
        XCTAssertEqual(row.accessibilityLabel,"Zukertort – Steinitz, World Championship 1886, Game 1, 0-1")
        // No source records how this game ended, so only who won is said.
        XCTAssertEqual(row.facts,"Black won · 46 moves · Slav Defense")
        XCTAssertEqual(catalog.sections(scope:.all,query:"ding gukesh game 3").first?.rows.first?.facts.map{$0.hasPrefix("Won on time")},true)
        // A match that ran into a second year is found by that year.
        XCTAssertTrue(catalog.sections(scope:.all,query:"1891").flatMap(\.rows).contains{$0.id.hasPrefix("library:wch-1890-")})
        XCTAssertEqual(catalog.classics.first{$0.id=="library:legal-mate"}?.details,"traditional finish")
    }
    /// Plan WI-16 budgets, measured where the tests run (the test host): loading the library and building the catalog
    /// for 200 bundled and 5,000 imported rows within 300 ms; each keystroke's filter within 50 ms.
    func testPerformanceBudgets() throws {
        let records=(0..<5000).map{i in "[Event \"Club \(i % 40)\"]\n[White \"Player\(i)\"]\n[Black \"Rival\(i % 300)\"]\n[Date \"\(1950+i % 70).01.01\"]\n[Result \"1-0\"]\n[Opening \"Opening \(i % 90)\"]\n\n1. e4 e5 1-0\n"}.joined(separator:"\n")
        XCTAssertEqual(try GameCollectionStore(directory:library).importCollection(Data(records.utf8),name:"big.pgn").records.count,5000)
        // 200 bundled rows as the plan specifies: the bundle's own games plus synthetic copies under new ids.
        func padded(_ bundled:GameLibrary)throws -> GameLibrary {
            let extra=try (0..<max(0,200-bundled.games.count)).map{i -> LibraryGame in
                var object=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(bundled.games[i % bundled.games.count])) as? [String:Any]);object["id"]="synthetic-\(i)"
                return try JSONDecoder().decode(LibraryGame.self,from:JSONSerialization.data(withJSONObject:object))
            }
            return GameLibrary(events:bundled.events,games:bundled.games+extra,directory:bundled.directory)
        }
        // Timed as the workspace pays for it: the bundle's manifest, the collection folder and its index decoding, the catalog.
        let started=Date()
        let bundled=try padded(GameLibrary.load()),found=try GameCollectionStore(directory:library).load()
        let catalog=LibraryCatalog(library:bundled,collections:found.collections,broken:found.broken);let built=Date().timeIntervalSince(started)
        XCTAssertEqual(bundled.games.count,200);XCTAssertEqual(catalog.rowCount,5200);XCTAssertLessThan(built,0.3,"Loading and building took \(built) s")
        var slowest=0.0
        for query in ["k","ka","kar","karp","karpo","karpov","player12","rival 7","1972","opening 4"] {
            let start=Date();_=catalog.sections(scope:.all,query:query);slowest=max(slowest,Date().timeIntervalSince(start))
        }
        XCTAssertLessThan(slowest,0.05,"The slowest keystroke took \(slowest) s")
        print("Game library budgets: load and build \(Int(built*1000)) ms, slowest keystroke \(Int(slowest*1000)) ms, \(catalog.rowCount) rows")
    }
    // MARK: Adversarial input and concurrent stores (audit round 1)
    func testMillionsOfEmptyRecordsAreRejectedEarly() throws {
        var data=Data();data.reserveCapacity(4_000_000);for _ in 0..<2_000_000{data.append(contentsOf:Array("*\n".utf8))}
        var tokens=0
        XCTAssertThrowsError(try PGNImporter.splitRecords(data,maximumRecords:GameCollectionStore.maximumRecords,cancelled:{tokens+=1;return false}))
        // Rejected as soon as the limit passes: a full read would check for cancellation about 15,600 times.
        XCTAssertLessThan(tokens,2_000,"The limit was checked only after \(tokens) cancellation checks")
    }
    /// A record opened for review is routed by how many readable games it holds, counted by the lexer alone, so a file
    /// with more games than a review reads still reaches the collection path.
    func testSeveralReadableGamesAreCountedByTheLexer() throws {
        let games=(1...ReviewPolicy.maximumRecords+1).map{"[White \"W\($0)\"]\n[Black \"B\($0)\"]\n\n1. e4 e5 *"}.joined(separator:"\n\n")
        XCTAssertTrue(PGNImporter.holdsSeveralRecords(Data(games.utf8)))
        XCTAssertEqual(try PGNImporter.splitRecords(Data(games.utf8),maximumRecords:1,stoppingAt:2).records.count,2,"counting stops at the second game, before any limit")
        XCTAssertFalse(PGNImporter.holdsSeveralRecords(Data("1. e4 e5 *".utf8)))
        XCTAssertFalse(PGNImporter.holdsSeveralRecords(Data("[Event \"Bad\\q\"]\n\n1. d4 *\n\n[Event \"Good\"]\n\n1. e4 *\n".utf8)),"an unreadable record is not a game")
    }
    func testABrokenHeaderDoesNotSalvageTheRestOfItsRecord() throws {
        let text="[Event \"Bad\"]\n[White \"Esc\\q\"]\n[Black \"Gamma\"]\n[Result \"1-0\"]\n\n1. e4 e5 1-0\n\n[Event \"Good\"]\n[White \"A\"]\n[Black \"B\"]\n[Result \"0-1\"]\n\n1. f3 e5 2. g4 Qh4# 0-1\n"
        let split=try PGNImporter.splitRecords(Data(text.utf8),maximumRecords:100,cancelled:{false})
        XCTAssertEqual(split.records.map{$0.tags["Event"]},["Good"]);XCTAssertEqual(split.unreadable,1)
    }
    /// A malformed first header straight after a finished record and a blank line is read once, not rediscovered.
    func testAMalformedHeaderAfterARecordIsCountedOnce() throws {
        let text="[Event \"One\"]\n[Result \"1-0\"]\n\n1. e4 1-0\n\n[Event \"Bad\\q\"]\n[Result \"0-1\"]\n\n1. d4 0-1\n\n[Event \"Two\"]\n[Result \"0-1\"]\n\n1. c4 0-1\n"
        let split=try PGNImporter.splitRecords(Data(text.utf8),maximumRecords:3,cancelled:{false})  // counted twice, it would pass the limit
        XCTAssertEqual(split.records.compactMap{$0.tags["Event"]},["One","Two"]);XCTAssertEqual(split.unreadable,1)
    }
    func testAnUnclosedCommentRecoversAtTheNextRecord() throws {
        let text="[Event \"Open\"]\n[Result \"*\"]\n\n1. e4 { never closed\n\n[Event \"Second\"]\n[Result \"1-0\"]\n\n1. e4 1-0\n\n[Event \"Third\"]\n[Result \"0-1\"]\n\n1. d4 0-1\n"
        let split=try PGNImporter.splitRecords(Data(text.utf8),maximumRecords:100,cancelled:{false})
        XCTAssertEqual(split.records.compactMap{$0.tags["Event"]},["Second","Third"]);XCTAssertEqual(split.unreadable,1)
    }
    /// Record boundaries are found with CRLF and lone-CR line endings too, as the lexer accepts both.
    func testRecoveryFindsRecordsWithEveryLineEnding() throws {
        let text="[Event \"Open\"]\n[Result \"*\"]\n\n1. e4 { never closed\n\n[Event \"Second\"]\n[Result \"1-0\"]\n\n1. e4 1-0\n\n[Event \"Third\"]\n[Result \"0-1\"]\n\n1. d4 0-1\n"
        for ending in ["\r\n","\r"] {
            let split=try PGNImporter.splitRecords(Data(text.replacingOccurrences(of:"\n",with:ending).utf8),maximumRecords:100,cancelled:{false})
            XCTAssertEqual(split.records.compactMap{$0.tags["Event"]},["Second","Third"],ending.debugDescription);XCTAssertEqual(split.unreadable,1)
        }
    }
    func testTagsAreBoundedByScalars() throws {
        let tag="a"+String(repeating:"\u{301}",count:5000)
        let text="[Event \"\(tag)\"]\n[White \"A\"]\n[Black \"B\"]\n[Result \"1-0\"]\n\n1. e4 1-0\n"
        let index=try GameCollectionStore(directory:library).importCollection(Data(text.utf8),name:tag)
        XCTAssertLessThanOrEqual(try XCTUnwrap(index.records.first?.tags["Event"]).unicodeScalars.count,GameCollectionStore.maximumTag)
        XCTAssertLessThanOrEqual(index.name.unicodeScalars.count,GameCollectionStore.maximumName)
    }
    /// Two stores on one folder share its lock: together they never pass the quota, and neither removes the other's files.
    func testTwoStoresShareTheQuota() throws {
        func collection(_ n:Int)->Data {Data(((0..<60).map{i in "[Event \"S\(n)-\(i)\"]\n[White \"W\"]\n[Black \"B\"]\n[Result \"1-0\"]\n\n1. e4 e5 1-0\n"}.joined(separator:"\n")).utf8)}
        // Room for two and a half collections, measured with their indexes.
        let scratch=folder.appendingPathComponent("scratch");_=try GameCollectionStore(directory:scratch).importCollection(collection(0),name:"0.pgn")
        let one=GameCollectionStore(directory:scratch).usedBytes(),quota=one*5/2
        let stores=[GameCollectionStore(directory:library,quotaBytes:quota),GameCollectionStore(directory:library,quotaBytes:quota)]
        var successes=0;let counter=NSLock()
        DispatchQueue.concurrentPerform(iterations:8){i in if (try? stores[i%2].importCollection(collection(i),name:"\(i).pgn")) != nil{counter.lock();successes+=1;counter.unlock()}}
        XCTAssertLessThanOrEqual(stores[0].usedBytes(),quota);XCTAssertEqual(successes,2)
        XCTAssertEqual(try stores[1].load().collections.count,successes)
        // The same bytes imported concurrently through both are stored once and charged once.
        try FileManager.default.removeItem(at:library)
        DispatchQueue.concurrentPerform(iterations:6){i in _=try? stores[i%2].importCollection(collection(99),name:"same.pgn")}
        XCTAssertEqual(try stores[0].load().collections.count,1)
    }
    /// A failed index write leaves no collection file behind.
    func testAFailedIndexWriteRollsBackTheFile() throws {
        let data=Data(fixture.utf8),sha=reviewHash(data)
        try FileManager.default.createDirectory(at:library,withIntermediateDirectories:true)
        // A directory where the index belongs makes its rename fail.
        try FileManager.default.createDirectory(at:library.appendingPathComponent(sha+".index.json/blocker"),withIntermediateDirectories:true)
        XCTAssertThrowsError(try GameCollectionStore(directory:library).importCollection(data,name:"fixture.pgn"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:library.appendingPathComponent(sha+".pgn").path))
    }
    /// Importing over an unreadable index charges only the difference, not the whole replacement.
    func testReplacingAnUnreadableIndexChargesTheDifference() throws {
        let data=Data(fixture.utf8),sha=reviewHash(data)
        _=try GameCollectionStore(directory:library).importCollection(data,name:"fixture.pgn")
        let used=GameCollectionStore(directory:library).usedBytes(),indexURL=library.appendingPathComponent(sha+".index.json")
        let size=try XCTUnwrap(FileManager.default.attributesOfItem(atPath:indexURL.path)[.size] as? Int)
        try Data(repeating:UInt8(ascii:"x"),count:size).write(to:indexURL)
        // The new index records a new import time, whose JSON number can be a few bytes longer than the old one's, so
        // the quota allows 64 bytes of growth: still far less than the index itself, which charging it whole would need.
        XCTAssertGreaterThan(size,4*64)
        XCTAssertNoThrow(try GameCollectionStore(directory:library,quotaBytes:used+64).importCollection(data,name:"fixture.pgn"))
    }
    /// A rebuilt index is charged to the quota: over it, the collection is reported broken instead of growing the folder.
    func testARebuiltIndexIsChargedToTheQuota() throws {
        let data=Data(fixture.utf8),sha=reviewHash(data)
        _=try GameCollectionStore(directory:library).importCollection(data,name:"fixture.pgn")
        try FileManager.default.removeItem(at:library.appendingPathComponent(sha+".index.json"))
        let found=try GameCollectionStore(directory:library,quotaBytes:data.count+10).load()
        XCTAssertEqual(found.collections.count,0);XCTAssertEqual(found.broken.map(\.id),[sha])
        XCTAssertFalse(FileManager.default.fileExists(atPath:library.appendingPathComponent(sha+".index.json").path))
    }
    /// R-22: a rebuilt index keeps the name the collection was imported with; without it, the most common Event names
    /// the collection, and a damaged collection is shown under its name too.
    func testARebuiltIndexKeepsTheCollectionsName() throws {
        let store=GameCollectionStore(directory:library),data=Data("[Event \"Wch\"]\n\n1. e4 *\n\n[Event \"Blitz\"]\n\n1. c4 *\n\n[Event \"Wch\"]\n\n1. d4 *\n\n[Event \"?\"]\n\n1. f4 *\n\n[Event \"?\"]\n\n1. g3 *\n".utf8)
        let index=try store.importCollection(data,name:"Kasparov games.pgn"),sha=index.sha256
        let indexURL=library.appendingPathComponent(sha+".index.json"),nameURL=library.appendingPathComponent(sha+".name")
        try FileManager.default.removeItem(at:indexURL)
        XCTAssertEqual(try store.load().collections.map(\.name),["Kasparov games.pgn"])
        XCTAssertEqual(try JSONDecoder().decode(CollectionIndex.self,from:Data(contentsOf:indexURL)).name,"Kasparov games.pgn","the rebuilt index holds the name")
        // A collection from an older build has an index but no stored name: loading stores it.
        try FileManager.default.removeItem(at:nameURL);XCTAssertEqual(try store.load().collections.map(\.name),["Kasparov games.pgn"])
        XCTAssertEqual(try String(contentsOf:nameURL,encoding:.utf8),"Kasparov games.pgn")
        // With neither, the most common known Event names it.
        try FileManager.default.removeItem(at:nameURL);try FileManager.default.removeItem(at:indexURL)
        XCTAssertEqual(try store.load().collections.map(\.name),["Wch"])
        let plain=try store.importCollection(Data("1. e4 *\n".utf8),name:"plain.pgn")
        try FileManager.default.removeItem(at:library.appendingPathComponent(plain.sha256+".name"));try FileManager.default.removeItem(at:library.appendingPathComponent(plain.sha256+".index.json"))
        XCTAssertEqual(Set(try store.load().collections.map(\.name)),["Wch","Collection"],"no Event: the generic name")
        try Data("changed".utf8).write(to:library.appendingPathComponent(plain.sha256+".pgn"));try "Plain games".write(to:library.appendingPathComponent(plain.sha256+".name"),atomically:true,encoding:.utf8)
        XCTAssertEqual(try store.load().broken.map(\.name),["Plain games"])
        // Removing a collection removes its name; a name left without its collection is cleared away.
        try store.remove(sha);XCTAssertFalse(FileManager.default.fileExists(atPath:nameURL.path))
        try "Orphan".write(to:nameURL,atomically:true,encoding:.utf8);_ = try store.load();XCTAssertFalse(FileManager.default.fileExists(atPath:nameURL.path))
    }
}
