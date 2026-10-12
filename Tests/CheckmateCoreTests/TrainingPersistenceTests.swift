import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-003: the optional `training` object in `state-v1.json`. A bad or newer record is kept verbatim through unrelated
/// saves; the budget prunes only disposable records; export, import and backup restore carry it with the boards.
@MainActor final class TrainingPersistenceTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent("training-"+UUID().uuidString)}
    override func tearDown(){try? FileManager.default.removeItem(at:directory)}
    private func savedTraining(_ store:StateStore)throws -> JSONValue? {try JSONDecoder().decode([String:JSONValue].self,from:Data(contentsOf:store.url))["training"]}
    private func stateJSON(training:Any)throws -> Data {
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(ApplicationState())) as! [String:Any];object["training"]=training
        return try JSONSerialization.data(withJSONObject:object)
    }
    private func event(_ n:Int)->TrainingCompletionEvent {TrainingCompletionEvent(id:"e\(n)",kind:"pawn-duel",run:"r\(n)",winner:"w",drawReason:nil,computer:true,origin:"library",at:Date(timeIntervalSince1970:Double(n)))}
    func testMissingTrainingStartsEmptyAndOldSavesAreUnchanged()throws {
        var object=try JSONSerialization.jsonObject(with:JSONEncoder().encode(ApplicationState())) as! [String:Any];object.removeValue(forKey:"training")
        let state=try JSONDecoder().decode(ApplicationState.self,from:JSONSerialization.data(withJSONObject:object))
        XCTAssertNil(state.training);XCTAssertTrue(state.trainingWritable)
        let written=try JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as! [String:Any]
        XCTAssertNil(written["training"],"a save with no training writes no key");XCTAssertEqual(written["schemaVersion"] as? Int,1)
    }
    func testFutureAndUnreadableTrainingSurviveAnUnrelatedSaveVerbatim()throws {
        let store=StateStore(directory:directory)
        let future:[String:Any]=["version":7,"lessons":["deep":["nested":[1,2,["x":true]]]],"active":NSNull()]
        let unreadable:[String:Any]=["version":1,"attempts":"truncated","extra":["kept":"yes"]]
        for (record,issue) in [(future,"future"),(unreadable,"unreadable")] {
            let original=try JSONDecoder().decode(JSONValue.self,from:JSONSerialization.data(withJSONObject:record))
            var state=try JSONDecoder().decode(ApplicationState.self,from:stateJSON(training:record))
            XCTAssertEqual(state.trainingIssue,issue);XCTAssertFalse(state.trainingWritable);XCTAssertNil(state.training)
            // An unrelated settings change is saved and reopened: the record is byte-for-byte the same value.
            state.settings.boardTheme="blue";try store.save(state)
            let reopened=try store.load()
            XCTAssertEqual(try savedTraining(store),original,issue);XCTAssertEqual(reopened.settings.boardTheme,"blue");XCTAssertEqual(reopened.trainingRaw,original)
            // Recording is refused rather than replacing it.
            var copy=reopened;XCTAssertThrowsError(try TrainingStore.finish(TrainingSessionSnapshot(id:"s",entry:"reach-target",scenario:Self.scenario,freshness:"new",startedAt:Date()),outcome:.correct,in:&copy,now:Date(),calendar:.current))
            XCTAssertNil(TrainingStore.recordLegacyCompletion(Self.finishedPawnDuel(),origin:"library",in:&copy,now:Date(),calendar:.current));XCTAssertEqual(copy.trainingRaw,original)
        }
    }
    func testOnlyAnUnreadableRecordCanBeExplicitlyReset()throws {
        var unreadable=try JSONDecoder().decode(ApplicationState.self,from:stateJSON(training:["version":1,"attempts":"truncated"]))
        try TrainingStore.resetUnreadable(in:&unreadable);XCTAssertTrue(unreadable.trainingWritable);XCTAssertEqual(unreadable.training,TrainingState())
        var future=try JSONDecoder().decode(ApplicationState.self,from:stateJSON(training:["version":2]))
        XCTAssertThrowsError(try TrainingStore.resetUnreadable(in:&future));XCTAssertEqual(future.trainingRaw,.object(["version":.number(2)]))
        var fine=ApplicationState();XCTAssertThrowsError(try TrainingStore.resetUnreadable(in:&fine))
    }
    func testUnknownFieldsInsideAReadableRecordAreKeptForADowngrade()throws {
        var record=try JSONSerialization.jsonObject(with:JSONEncoder().encode(TrainingState())) as! [String:Any];record["laterField"]=["a":1]
        var state=try JSONDecoder().decode(ApplicationState.self,from:stateJSON(training:record))
        XCTAssertNotNil(state.training);state.settings.volume=0.5
        let store=StateStore(directory:directory);try store.save(state)
        guard case .object(let saved)=try savedTraining(store) else{return XCTFail("training was not written")}
        XCTAssertEqual(saved["laterField"],.object(["a":.number(1)]))
    }
    func testPruningKeepsCountersAndTheActiveAttempt()throws {
        var training=TrainingState();training.events=(0..<260).map(event);training.summaries["pawn-duel"]=TrainingEntrySummary();training.summaries["pawn-duel"]?.legacyWins=260
        training.active=TrainingSessionSnapshot(id:"active",entry:"reach-target",scenario:Self.scenario,freshness:"new",startedAt:Date())
        training.summaries["reach-target"]=TrainingEntrySummary();training.summaries["reach-target"]?.days=(0..<400).map{"d\($0)"}
        TrainingStore.prune(&training)
        XCTAssertEqual(training.events.count,TrainingState.maximumEvents);XCTAssertEqual(training.events.first?.id,"e60","the newest are kept")
        XCTAssertEqual(training.summaries["pawn-duel"]?.legacyWins,260,"counters are never pruned");XCTAssertEqual(training.active?.id,"active")
        XCTAssertEqual(training.summaries["reach-target"]?.days.count,TrainingState.maximumDays);XCTAssertNoThrow(try training.validate())
    }
    func testAnAttemptTooLargeToSaveIsRefusedBeforeItStarts()throws {
        let huge=TrainingScenario(id:"huge",entry:"reach-target",variant:"rook",tier:1,cluster:"c",learner:"w",prompt:String(repeating:"x",count:TrainingState.maximumBytes),explanation:"",hints:[],drill:Self.scenario.drill,budget:2)
        XCTAssertFalse(TrainingStore.fits(TrainingSessionSnapshot(id:"s",entry:"reach-target",scenario:huge,freshness:"new",startedAt:Date()),in:TrainingState()))
        XCTAssertTrue(TrainingStore.fits(TrainingSessionSnapshot(id:"s",entry:"reach-target",scenario:Self.scenario,freshness:"new",startedAt:Date()),in:TrainingState()))
    }
    func testASaveErrorLeavesTheLastGoodFileInPlace()throws {
        let store=StateStore(directory:directory);var state=ApplicationState();state.training=TrainingState();try store.save(state)
        let good=try Data(contentsOf:store.url)
        state.training?.events=(0..<TrainingState.maximumEvents+1).map(event)
        XCTAssertThrowsError(try store.save(state),"an out-of-bounds record is refused, not written")
        XCTAssertEqual(try Data(contentsOf:store.url),good)
    }
    func testExportImportAndBackupRestoreCarryTrainingWithTheBoards()throws {
        let store=StateStore(directory:directory)
        var first=ApplicationState();first.training=TrainingState();first.training?.events=[event(1)];first.training?.creditedRuns["pawn-duel"]="r1";first.miniGames=["pawn-duel":MiniGameState(kind:.pawnDuel)]
        try store.save(first)
        var second=first;second.training?.events.append(event(2));second.miniGames=nil;try store.save(second)
        try store.restoreBackup()
        let restored=try store.load();XCTAssertEqual(restored.training,first.training);XCTAssertEqual(restored.miniGames,first.miniGames,"training and boards come from the same snapshot")
        let archive=directory.appendingPathComponent("export.json");try store.exportState(second,to:archive)
        let imported=try JSONDecoder().decode(ApplicationState.self,from:Data(contentsOf:archive));XCTAssertEqual(imported.training,second.training)
        let session=try GameSession(engine:nil);try session.installImportedState(imported)
        XCTAssertEqual(session.state.training,second.training);XCTAssertEqual(session.activity,.at(.practice),"import never opens a training board")
    }
    static let scenario=TrainingScenario(id:"t",entry:"reach-target",variant:"rook",tier:1,cluster:"c",learner:"w",prompt:"Reach h8.",explanation:"",hints:[],drill:MovementDrill(piece:"wr",start:"a1",target:"h8",pieces:[:]),budget:2)
    static func finishedPawnDuel()->MiniGameState {var game=MiniGameState(kind:.pawnDuel,computer:false);game.snapshot.board=["a7":"wp","h7":"bp"];_ = game.play(MiniGameMove(from:"a7",to:"a8"));return game}
}
