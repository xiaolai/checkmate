import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateSupport
@testable import CheckmateRules
@testable import CheckmateApplication

/// The WI-026 release's reading of scenario-bearing training records, frozen as data before WI-017 added any value
/// (`Tests/Fixtures/TrainingCompatibility/release-decoder.json`), so a later build's tests can ask what this release
/// does with the records that build writes. It models what later builds add (fields and closed-vocabulary values),
/// not types or required fields; `TrainingCompatibilityTests` ties it to this release's decoder.
struct FrozenTrainingDecoder {
    enum Verdict:String {case readable,newer,damaged}
    static let directory=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/TrainingCompatibility")
    private let records:[String:[String:Any]],shapes:[String:Any]
    init()throws {
        let model=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:Self.directory.appendingPathComponent("release-decoder.json"))) as? [String:Any])
        records=try XCTUnwrap(model["records"] as? [String:[String:Any]]);shapes=try XCTUnwrap(model["shapes"] as? [String:Any])
    }
    /// The fields the release knows in a `kind` record: the ones it decodes and writes back; nil for a kind it has not.
    func fields(of kind:String)->Set<String>? {(records[kind]?["fields"] as? [String:Any]).map{Set($0.keys)}}
    /// `kind` is `active` or `retry`.
    func verdict(_ record:Any,as kind:String)->Verdict {
        guard let fields=record as? [String:Any],fields["id"] is String,fields["entry"] is String,fields["scenario"] is [String:Any],let spec=records[kind],let known=spec["fields"] as? [String:Any] else{return .damaged}
        let tolerant=spec["toleratesUnknownFields"] as? Bool ?? false
        for (key,value) in fields where !(value is NSNull) {
            guard let shape=known[key] else{if tolerant{continue};return .newer}
            guard fits(value,shape) else{return .newer}
        }
        return .readable
    }
    private func fits(_ value:Any,_ shape:Any)->Bool {
        if value is NSNull{return true}
        if let name=shape as? String{return name=="value" || shapes[name].map{fits(value,$0)} ?? false}
        guard let shape=shape as? [String:Any] else{return false}
        if let values=shape["enum"] as? [String]{return (value as? String).map(values.contains) ?? false}
        if let fields=shape["object"] as? [String:Any]{guard let object=value as? [String:Any] else{return false};return object.allSatisfy{key,item in item is NSNull || fields[key].map{fits(item,$0)} ?? false}}
        if let item=shape["array"]{guard let array=value as? [Any] else{return false};return array.allSatisfy{fits($0,item)}}
        if let cases=shape["oneOf"] as? [String:Any]{guard let object=value as? [String:Any],object.count==1,let (name,payload)=object.first,let fields=cases[name] else{return false};return fits(payload,["object":fields])}
        return false
    }
}

/// WI-026: a newer version's scenario-bearing record is set aside on its own (kept raw in place, written back unchanged,
/// counted in the bounds, never resumed or scheduled) while the rest of training stays writable. The behaviour tests
/// make "newer" records from bundled ones with a value no build defines (`laterValue`), so they keep testing the
/// mechanism after later builds add their own values; putting the known value back is what a build that understands
/// the record reads, which shows it restored.
@MainActor final class TrainingCompatibilityTests:XCTestCase {
    /// A closed-vocabulary value no build defines.
    static let laterValue="fromALaterBuild"
    private let day=Date(timeIntervalSince1970:1_800_000_000)
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent("training-compat-"+UUID().uuidString)}
    override func tearDown(){try? FileManager.default.removeItem(at:directory)}

    private static func json<T:Encodable>(_ value:T)throws -> JSONValue {try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(value))}
    private static func any(_ value:JSONValue)throws -> Any {try JSONSerialization.jsonObject(with:JSONEncoder().encode(value),options:.fragmentsAllowed)}
    /// The record's bytes as the state file writes them (sorted keys), so equal bytes mean the record was not touched.
    private static func bytes(_ value:JSONValue)throws -> Data {try JSONSerialization.data(withJSONObject:any(value),options:[.sortedKeys,.fragmentsAllowed])}
    private static func replacing(_ value:JSONValue,_ old:String,with new:String)->JSONValue {
        switch value {
        case .string(let text):return .string(text==old ? new:text)
        case .array(let items):return .array(items.map{replacing($0,old,with:new)})
        case .object(let fields):return .object(fields.mapValues{replacing($0,old,with:new)})
        default:return value
        }
    }
    private static func setting(_ value:JSONValue,_ path:[String],to new:JSONValue)->JSONValue {
        guard let key=path.first,case .object(var fields)=value else{return value}
        fields[key]=path.count==1 ? new:setting(fields[key] ?? .object([:]),Array(path.dropFirst()),to:new);return .object(fields)
    }
    /// What this release does with one record: `TrainingState`'s own per-record reading.
    private static func live(_ record:JSONValue,as kind:String)->FrozenTrainingDecoder.Verdict {
        do{let usable=kind=="active" ? try TrainingState.readable(record,as:TrainingSessionSnapshot.self,whole:false) != nil:try TrainingState.readable(record,as:TrainingRetryItem.self,whole:true) != nil;return usable ? .readable:.newer}catch{return .damaged}
    }
    private func state(training:JSONValue)throws -> ApplicationState {
        var object=try JSONDecoder().decode([String:JSONValue].self,from:JSONEncoder().encode(ApplicationState()));object["training"]=training
        return try JSONDecoder().decode(ApplicationState.self,from:JSONEncoder().encode(object))
    }
    private func savedTraining(_ store:StateStore)throws -> JSONValue {try XCTUnwrap(JSONDecoder().decode([String:JSONValue].self,from:Data(contentsOf:store.url))["training"])}
    private static func queue(_ training:JSONValue)->[JSONValue] {if case .object(let fields)=training,case .array(let items)?=fields["retryQueue"]{return items};return []}
    private static func field(_ training:JSONValue,_ key:String)->JSONValue? {if case .object(let fields)=training{return fields[key]};return nil}
    private static func id(_ record:JSONValue)->String? {if case .object(let fields)=record,case .string(let id)?=fields["id"]{return id};return nil}

    /// A bundled searched scenario (it names its evaluator), and the same one as a newer build would write it.
    private static func material()throws -> (known:TrainingScenario,newer:JSONValue) {
        let scenario=try XCTUnwrap(TrainingScenarioProvider.bundled().scenarios(for:"capture-wisely").first{$0.check == .material})
        return (scenario,setting(try json(scenario),["check"],to:.string(laterValue)))
    }
    private func drill(_ provider:TrainingScenarioProvider,seed:UInt64)throws -> TrainingScenario {
        guard case .scenario(let scenario,_)=provider.next(for:try XCTUnwrap(provider.catalog.entry("reach-target")),seen:[],seed:seed) else{throw XCTSkip("no drill")}
        return scenario
    }
    private func retryItem(_ id:String,_ scenario:TrainingScenario)->TrainingRetryItem {TrainingRetryItem(id:id,entry:scenario.entry,scenario:scenario,reason:"Not solved last time.",addedAt:day.addingTimeInterval(-3*86_400),notBefore:"2027-01-13",afterAttempt:0)}
    private static func retryJSON(_ id:String,scenario:JSONValue,entry:String,day:Date)throws -> JSONValue {
        guard case .object(var fields)=try json(TrainingRetryItem(id:id,entry:entry,scenario:TrainingPersistenceTests.scenario,reason:"Not solved last time.",addedAt:day.addingTimeInterval(-3*86_400),notBefore:"2027-01-13",afterAttempt:0)) else{return .null}
        fields["scenario"]=scenario;return .object(fields)
    }
    /// A session whose every save is written to `store`, as the app's are; save failures are collected, never ignored.
    private func makeSession(_ state:ApplicationState,store:StateStore,failures:@escaping (Error)->Void)throws -> (GameSession,LearningPlayer,TrainingController) {
        let session=try GameSession(engine:nil,state:state),player=try LearningPlayer(session:session)
        session.onPersist={do{try store.save($0)}catch{failures(error)}}
        let controller=TrainingController(session:session,learning:player,provider:try TrainingScenarioProvider.bundled())
        var seed:UInt64=11;controller.seed={seed+=1;return seed};controller.now={[day] in day}
        controller.calendar=Calendar(identifier:.gregorian);controller.calendar.timeZone=TimeZone(identifier:"UTC")!
        return (session,player,controller)
    }
    private func solveDrill(_ controller:TrainingController)throws {
        for _ in 0..<16 {
            let exercise=try XCTUnwrap(controller.exercise);guard !exercise.finished,let drill=exercise.scenario.drill,let state=exercise.drillState,let left=drill.distance(from:state) else{return}
            let step=try XCTUnwrap(drill.moves(state).first{move in drill.apply(state,to:move.to).flatMap{drill.distance(from:$0)}==left-1})
            controller.attempt(from:state.square,to:step.to,promotion:nil)
        }
    }

    // MARK: The frozen fixture

    func testTheFrozenDecoderGivesEachFixtureRecordItsRecordedVerdict()throws {
        let frozen=try FrozenTrainingDecoder()
        let manifest=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:FrozenTrainingDecoder.directory.appendingPathComponent("records.json"))) as? [String:Any])
        let records=try XCTUnwrap(manifest["records"] as? [[String:Any]])
        XCTAssertEqual(Set(records.compactMap{$0["verdict"] as? String}),["readable","newer","damaged"])
        for record in records {
            let name=try XCTUnwrap(record["name"] as? String),kind=try XCTUnwrap(record["kind"] as? String),verdict=try XCTUnwrap(record["verdict"] as? String),body=try XCTUnwrap(record["json"])
            XCTAssertEqual(frozen.verdict(body,as:kind).rawValue,verdict,name)
            // Later builds read everything this release read, and nothing they cannot read is readable here.
            let live=Self.live(try JSONDecoder().decode(JSONValue.self,from:JSONSerialization.data(withJSONObject:body,options:.fragmentsAllowed)),as:kind)
            if verdict=="readable"{XCTAssertEqual(live,.readable,name)}
            if live != .readable{XCTAssertNotEqual(verdict,"readable",name)}
        }
    }
    /// The frozen model and this release's decoder agree: on every bundled scenario as an attempt and as a retry item, and
    /// on each kind of addition a later build can make (always with a value or field no build defines).
    func testTheFrozenDecoderAgreesWithThisRelease()throws {
        let frozen=try FrozenTrainingDecoder(),provider=try TrainingScenarioProvider.bundled()
        func check(_ record:JSONValue,_ kind:String,_ expected:FrozenTrainingDecoder.Verdict?,_ label:String)throws {
            let model=frozen.verdict(try Self.any(record),as:kind),live=Self.live(record,as:kind)
            if let expected{XCTAssertEqual(live,expected,label);XCTAssertEqual(model,expected,label)}
            // A record the frozen release reads, every later build reads.
            else if model == .readable{XCTAssertEqual(live,.readable,label)}
        }
        var scenarios=provider.catalog.entries.flatMap{provider.scenarios(for:$0.id)}
        scenarios+=try (1...6).map{try drill(provider,seed:$0)}
        XCTAssertGreaterThan(scenarios.count,100)
        for scenario in scenarios {
            let active=try Self.json(TrainingSessionSnapshot(id:"a-"+scenario.id,entry:scenario.entry,scenario:scenario,freshness:"new",startedAt:day,actions:[.move(from:"a1",to:"a2",promotion:nil),.hint(level:1),.reveal,.undo,.reply("e7e5"),.claim("threefold"),.choose("x"),.submit(squares:["a1"])],recordedHelp:true))
            try check(active,"active",nil,scenario.id);try check(Self.retryJSON("r-"+scenario.id,scenario:Self.json(scenario),entry:scenario.entry,day:day),"retry",nil,scenario.id)
        }
        let (known,_)=try Self.material(),scenario=try Self.json(known),later=JSONValue.string(Self.laterValue)
        let additions:[(String,JSONValue)]=[
            ("an unknown check",Self.setting(scenario,["check"],to:later)),("an unknown goal kind",Self.setting(scenario,["goal","kind"],to:later)),
            ("an unknown skill",Self.setting(scenario,["skills"],to:.array([later]))),("an unknown primary skill",Self.setting(scenario,["primarySkill"],to:later)),
            ("an unknown bridge",Self.setting(scenario,["bridge"],to:later)),("an unknown scenario field",Self.setting(scenario,[Self.laterValue],to:.array([.string("b")]))),
            ("an unknown goal field",Self.setting(scenario,["goal",Self.laterValue],to:.bool(true))),("an unknown review field",Self.setting(scenario,["review",Self.laterValue],to:.integer(1))),
        ]
        for (label,newer) in additions {
            try check(Self.json(TrainingSessionSnapshot(id:"a",entry:known.entry,scenario:TrainingPersistenceTests.scenario,freshness:"new",startedAt:day)).replacingScenario(newer),"active",.newer,label)
            try check(Self.retryJSON("r",scenario:newer,entry:known.entry,day:day),"retry",.newer,label)
        }
        let base=try Self.json(TrainingSessionSnapshot(id:"a",entry:known.entry,scenario:known,freshness:"new",startedAt:day))
        try check(Self.setting(base,["actions"],to:.array([.object([Self.laterValue:.object([:])])])),"active",.newer,"an unknown action")
        try check(Self.setting(base,["actions"],to:.array([.object(["move":.object(["from":.string("a1"),"to":.string("a2"),Self.laterValue:.bool(true)])])])),"active",.newer,"an unknown action field")
        // Configuration beside the scenario: the frozen release keeps it by path and resumes the attempt. Since WI-017
        // this build reads `opponent` itself, so a strategy it does not know sets the attempt aside here (plan D8).
        let unknownStrategy=Self.setting(base,["opponent"],to:.object(["strategy":later]))
        XCTAssertEqual(frozen.verdict(try Self.any(unknownStrategy),as:"active"),.readable,"the frozen release keeps it by path, and the attempt resumes there")
        XCTAssertEqual(Self.live(unknownStrategy,as:"active"),.newer,"an unknown strategy is from a newer version here")
        try check(Self.setting(Self.retryJSON("r",scenario:scenario,entry:known.entry,day:day),["level"],to:later),"retry",.newer,"an unknown retry field")
        try check(.integer(3),"retry",.damaged,"not an object");try check(.object(["id":.string("x"),"entry":.string("y")]),"active",.damaged,"no scenario")
    }

    /// WI-017's own values, as this build writes them, read by the frozen WI-026 release: a position game, active or
    /// queued, is set aside there as from a newer version, never damaged; an existing game's frozen opponent, of every
    /// level and legacy, sits beside its scenario, so that release keeps it by path and continues the attempt.
    func testTheFrozenReleaseSetsAsideThisBuildsPositionGamesAndKeepsTheirOpponentsByPath()throws {
        let frozen=try FrozenTrainingDecoder()
        func verdicts(_ record:JSONValue,_ kind:String)throws -> (frozen:FrozenTrainingDecoder.Verdict,live:FrozenTrainingDecoder.Verdict) {(frozen.verdict(try Self.any(record),as:kind),Self.live(record,as:kind))}
        let review=TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion)
        let race=TrainingScenario(id:"race-e",entry:"pawn-race",variant:"kpk",tier:1,cluster:"kpk-e",learner:"w",prompt:"Promote and keep the new piece.",explanation:"Lead with the king.",hints:["Keep the king in front."],fen:"4k3/8/8/8/8/8/4P3/4K3 w - - 0 1",review:review,check:.positionGame,goal:TrainingGoal(kind:.promoteAndHold,threshold:0))
        let bishops=TrainingScenario(id:"kbbk-1",entry:"two-bishop-mate",variant:"kbbk",tier:1,cluster:"kbbk",learner:"w",prompt:"Checkmate with the two bishops.",explanation:"Side by side.",hints:["Keep them together."],fen:"4k3/8/8/8/8/8/8/2B1KB2 w - - 0 1",review:review,check:.positionGame,goal:TrainingGoal(kind:.checkmate,threshold:0),keep:["b"])
        for scenario in [race,bishops] {
            for level in TrainingOpponentLevel.allCases {
                let active=try Self.json(TrainingSessionSnapshot(id:"a-"+scenario.id,entry:scenario.entry,scenario:scenario,freshness:"new",revision:3,startedAt:day,actions:[.move(from:"e1",to:"d2",promotion:nil),.reply("e8d7")],opponent:.frozen(level,attempt:"a-"+scenario.id,seed:0x3c,revision:3)))
                let read=try verdicts(active,"active")
                XCTAssertEqual(read.frozen,.newer,"set aside there, not broken: \(scenario.id) \(level)");XCTAssertEqual(read.live,.readable,"and read here")
            }
            let retry=try verdicts(try Self.retryJSON("r-"+scenario.id,scenario:Self.json(scenario),entry:scenario.entry,day:day),"retry")
            XCTAssertEqual(retry.frozen,.newer,scenario.id);XCTAssertEqual(retry.live,.readable,scenario.id)
        }
        let provider=try TrainingScenarioProvider.bundled()
        for scenario in provider.scenarios(for:"finish-the-game")+provider.scenarios(for:"guided-games").filter({$0.check == .guidedGame}) {
            var opponents=TrainingOpponentLevel.allCases.map{TrainingOpponentConfiguration.frozen($0,attempt:"a",seed:9,revision:2)}+[.legacy(attempt:"a",revision:2)]
            var mixed=opponents[0];mixed.mixed=true;mixed.severeStreak=1;opponents.append(mixed)
            for opponent in opponents {
                let active=try Self.json(TrainingSessionSnapshot(id:"a",entry:scenario.entry,scenario:scenario,freshness:"new",revision:2,startedAt:day,opponent:opponent))
                let read=try verdicts(active,"active")
                XCTAssertEqual(read.frozen,.readable,"kept by path there, and continued: \(scenario.id) \(opponent.profile)");XCTAssertEqual(read.live,.readable)
            }
        }
        // Such a state, read as the frozen release reads it, keeps the rest of training writable: the set-aside
        // mechanism itself is the one the tests below drive with a value no build defines.
        guard case .object(var record)=try Self.json(TrainingState()) else{return XCTFail("no record")}
        record["active"]=try Self.json(TrainingSessionSnapshot(id:"a",entry:race.entry,scenario:race,freshness:"new",startedAt:day,opponent:.frozen(.gentle,attempt:"a",seed:1)))
        record["retryQueue"] = .array([try Self.retryJSON("r",scenario:Self.json(bishops),entry:bishops.entry,day:day)])
        let here=try state(training:.object(record))
        XCTAssertTrue(here.trainingWritable);XCTAssertEqual(here.training?.active?.scenario,race,"this build reads its own position game");XCTAssertEqual(here.training?.retryQueue.first?.scenario,bishops)
    }

    // MARK: A newer retry item, no active attempt

    func testANewerRetryItemIsSetAsideWhileSupportedTrainingIsStartedFinishedAndSaved()throws {
        let provider=try TrainingScenarioProvider.bundled(),store=StateStore(directory:directory)
        let (known,newerScenario)=try Self.material(),first=retryItem("known-first",try drill(provider,seed:101)),last=retryItem("known-last",try drill(provider,seed:202))
        let newer=try Self.retryJSON("newer-retry",scenario:newerScenario,entry:known.entry,day:day)
        guard case .object(var record)=try Self.json({var t=TrainingState();t.finishedAttempts=3;return t}()) else{return XCTFail("no record")}
        record["retryQueue"] = .array([try Self.json(first),newer,try Self.json(last)])
        let loaded=try state(training:.object(record))
        // Read on its own: the rest stays writable, the newer item is neither scheduled nor counted as this build's.
        XCTAssertTrue(loaded.trainingWritable);XCTAssertNil(loaded.trainingRaw)
        let training=try XCTUnwrap(loaded.training)
        XCTAssertEqual(training.retryQueue.map(\.id),["known-first","known-last"]);XCTAssertEqual(training.newerRetryCount,1)
        try store.save(loaded)
        var failures:[Error]=[]
        let (session,player,controller)=try makeSession(try store.load(),store:store){failures.append($0)};defer{player.shutdown()}
        XCTAssertEqual(controller.suggestions.map(\.item.id).sorted(),["known-first","known-last"],"a newer item is never suggested")
        XCTAssertThrowsError(try controller.prepareRetry(id:"newer-retry"))
        XCTAssertEqual(controller.keptForNewerVersion,["A suggested board from a newer version of Checkmate is kept for it."])
        // Unrelated supported training: a retry of the item before it, solved (it leaves the queue), then a new drill
        // whose answer is shown (it joins the queue), each saved as it happens.
        controller.begin(try controller.prepareRetry(id:"known-first"));try solveDrill(controller);XCTAssertEqual(controller.exercise?.status,.correct)
        controller.begin(try controller.prepare(entry:"reach-target"));XCTAssertNotNil(session.state.training?.active,"this build's attempt is saved for Continue")
        controller.hint();controller.hint();controller.hint();XCTAssertEqual(controller.exercise?.status,.revealed)
        XCTAssertTrue(failures.isEmpty,"\(failures)")
        let saved=try savedTraining(store),queue=Self.queue(saved)
        XCTAssertEqual(session.state.training?.attempts.count,2);XCTAssertEqual(session.state.training?.finishedAttempts,5)
        // In place, byte for byte: the item it preceded is gone, so it now leads; the new item is queued after the rest.
        XCTAssertEqual(queue.map(Self.id),["newer-retry","known-last",session.state.training?.retryQueue.last?.id])
        XCTAssertEqual(try Self.bytes(queue[0]),try Self.bytes(newer))
        // Re-upgrade: a build that knows the value reads the item back as it was, in its place.
        let upgraded=try state(training:Self.replacing(saved,Self.laterValue,with:TrainingCheck.material.rawValue))
        XCTAssertEqual(upgraded.training?.newerRetryCount,0);XCTAssertEqual(upgraded.training?.retryQueue.first?.id,"newer-retry")
        XCTAssertEqual(upgraded.training?.retryQueue.first?.scenario,known);XCTAssertNoThrow(try upgraded.training?.validate())
    }
    func testNewerRetryItemsCountTowardTheQueueBoundAndAreNeverPrunedHere()throws {
        let provider=try TrainingScenarioProvider.bundled(),(known,newerScenario)=try Self.material()
        let newer=try (0..<TrainingState.maximumRetries-1).map{try Self.retryJSON("newer-\($0)",scenario:newerScenario,entry:known.entry,day:day)}
        guard case .object(var record)=try Self.json(TrainingState()) else{return XCTFail("no record")}
        record["retryQueue"] = .array(newer+[try Self.json(retryItem("known",try drill(provider,seed:7)))])
        var training=try XCTUnwrap(state(training:.object(record)).training)
        XCTAssertNoThrow(try training.validate())
        // A full queue drops the oldest of this build's items; the newer ones keep their places.
        let snapshot=TrainingSessionSnapshot(id:"s",entry:"reach-target",scenario:try drill(provider,seed:8),freshness:"new",startedAt:day)
        TrainingRecommendation.record(snapshot,outcome:.incorrect,in:&training,now:day,calendar:.current)
        XCTAssertEqual(training.newerRetryCount,TrainingState.maximumRetries-1);XCTAssertEqual(training.retryQueue.map(\.scenario),[snapshot.scenario])
        XCTAssertEqual(Self.queue(try Self.json(training)).prefix(newer.count).map{try? Self.bytes($0)},newer.map{try? Self.bytes($0)})
        // One more than the bound, counting the newer ones, is beyond what this build writes: the whole object is kept raw.
        record["retryQueue"] = .array(newer+[try Self.json(retryItem("a",try drill(provider,seed:9))),try Self.json(retryItem("b",try drill(provider,seed:10)))])
        let over=try state(training:.object(record));XCTAssertFalse(over.trainingWritable);XCTAssertEqual(over.trainingIssue,"unreadable")
        // And a newer item that shares an identifier with this build's is damage, not a newer record.
        record["retryQueue"] = .array([newer[0],try Self.json(retryItem("newer-0",try drill(provider,seed:11)))])
        XCTAssertFalse(try state(training:.object(record)).trainingWritable)
    }
    func testNewerRecordsCountTowardTheByteBudget()throws {
        let (known,newerScenario)=try Self.material(),bulky=Self.setting(newerScenario,["explanation"],to:.string(String(repeating:"x",count:TrainingState.maximumBytes)))
        guard case .object(var record)=try Self.json(TrainingState()) else{return XCTFail("no record")}
        record["retryQueue"] = .array([try Self.retryJSON("newer",scenario:bulky,entry:known.entry,day:day)])
        XCTAssertEqual(try state(training:.object(record)).trainingIssue,"unreadable","over the budget with its newer item, the object is kept whole")
        guard case .object(var active)=try Self.json(TrainingSessionSnapshot(id:"a",entry:known.entry,scenario:known,freshness:"new",startedAt:day)) else{return XCTFail("no attempt")}
        active["scenario"]=Self.setting(bulky,["explanation"],to:.string(String(repeating:"x",count:TrainingState.maximumBytes/2)))
        record["retryQueue"] = .array([]);record["active"] = .object(active)
        var training=try XCTUnwrap(state(training:.object(record)).training)
        XCTAssertNotNil(training.newerActive);XCTAssertGreaterThan(try JSONEncoder().encode(training).count,TrainingState.maximumBytes/2,"the kept attempt is in the encoded record")
        // Pruning makes room from this build's disposable records only; the newer attempt still takes its share.
        training.events=(0..<TrainingState.maximumEvents).map{TrainingCompletionEvent(id:"e\($0)",kind:"pawn-duel",run:"r\($0)",winner:"w",drawReason:String(repeating:"y",count:2_000),computer:true,origin:"library",at:day)}
        TrainingStore.prune(&training);XCTAssertTrue(TrainingStore.withinBudget(training));XCTAssertNotNil(training.newerActive)
        XCTAssertLessThan(training.events.count,TrainingState.maximumEvents,"events went to make room; the newer attempt did not")
    }

    // MARK: A newer active attempt

    func testANewerActiveAttemptIsKeptInPlaceWhileSupportedTrainingIsStartedFinishedAndSaved()throws {
        let provider=try TrainingScenarioProvider.bundled(),store=StateStore(directory:directory)
        let (known,newerScenario)=try Self.material(),queued=retryItem("known",try drill(provider,seed:303))
        let original=TrainingSessionSnapshot(id:"newer-attempt",entry:known.entry,scenario:known,freshness:"new",revision:3,startedAt:day.addingTimeInterval(-60),actions:[.hint(level:1)],recordedHelp:true)
        let newer=try Self.json(original).replacingScenario(newerScenario)
        guard case .object(var record)=try Self.json({var t=TrainingState();t.finishedAttempts=3;t.retryQueue=[queued];return t}()) else{return XCTFail("no record")}
        record["active"]=newer
        let loaded=try state(training:.object(record))
        XCTAssertTrue(loaded.trainingWritable);XCTAssertNil(loaded.training?.active);XCTAssertEqual(loaded.training?.newerActive,newer)
        try store.save(loaded)
        var failures:[Error]=[]
        let (session,player,controller)=try makeSession(try store.load(),store:store){failures.append($0)};defer{player.shutdown()}
        // Never resumed: no Continue, and the library and the agents' list say it is kept for the newer version.
        XCTAssertNil(controller.resumable);XCTAssertThrowsError(try controller.prepareResume())
        XCTAssertEqual(controller.keptForNewerVersion.count,1);XCTAssertTrue(controller.keptForNewerVersion[0].contains("newer version"))
        // Unrelated supported training starts without abandoning it, finishes and is saved; the retry queue still works.
        controller.begin(try controller.prepare(entry:"reach-target"));XCTAssertEqual(controller.exercise?.definition.id,"reach-target")
        XCTAssertNil(session.state.training?.active,"this build's attempt is not saved over the newer one");XCTAssertEqual(session.state.training?.attempts.count,0,"nothing was recorded as abandoned")
        try solveDrill(controller);XCTAssertEqual(controller.exercise?.status,.correct)
        controller.begin(try controller.prepareRetry(id:"known"));controller.hint();controller.hint();controller.hint();XCTAssertEqual(controller.exercise?.status,.revealed)
        controller.openLibrary()
        XCTAssertTrue(failures.isEmpty,"\(failures)")
        let saved=try savedTraining(store),reopened=try store.load()
        XCTAssertEqual(reopened.training?.attempts.map(\.outcome),[.correct,.revealed]);XCTAssertEqual(reopened.training?.finishedAttempts,5);XCTAssertTrue(reopened.trainingWritable)
        XCTAssertEqual(try Self.bytes(XCTUnwrap(Self.field(saved,"active"))),try Self.bytes(newer),"kept in place, byte for byte")
        // Re-upgrade: a build that knows the value resumes the attempt exactly as it was left.
        let upgraded=try state(training:Self.replacing(saved,Self.laterValue,with:TrainingCheck.material.rawValue))
        XCTAssertEqual(upgraded.training?.active,original);XCTAssertNil(upgraded.training?.newerActive);XCTAssertNoThrow(try upgraded.training?.validate())
        let (_,again,resuming)=try makeSession(upgraded,store:store){failures.append($0)};defer{again.shutdown()}
        XCTAssertEqual(resuming.resumable,original)
    }
    func testAStateCannotHoldAnActiveAttemptBesideANewerOne()throws {
        let (known,newerScenario)=try Self.material()
        guard case .object(var record)=try Self.json(TrainingState()) else{return XCTFail("no record")}
        record["active"]=try Self.json(TrainingSessionSnapshot(id:"n",entry:known.entry,scenario:known,freshness:"new",startedAt:day)).replacingScenario(newerScenario)
        var training=try XCTUnwrap(state(training:.object(record)).training)
        training.active=TrainingSessionSnapshot(id:"mine",entry:"reach-target",scenario:TrainingPersistenceTests.scenario,freshness:"new",startedAt:day)
        XCTAssertThrowsError(try training.validate());XCTAssertThrowsError(try JSONEncoder().encode(training),"never written over the newer attempt")
        XCTAssertTrue(TrainingStore.fits(TrainingSessionSnapshot(id:"s",entry:"reach-target",scenario:TrainingPersistenceTests.scenario,freshness:"new",startedAt:day),in:{var t=training;t.active=nil;return t}()))
    }
    func testTheAgentListSaysWhatIsKeptForANewerVersion()async throws {
        let (known,newerScenario)=try Self.material()
        guard case .object(var record)=try Self.json(TrainingState()) else{return XCTFail("no record")}
        record["active"]=try Self.json(TrainingSessionSnapshot(id:"n",entry:known.entry,scenario:known,freshness:"new",startedAt:day)).replacingScenario(newerScenario)
        record["retryQueue"] = .array([try Self.retryJSON("r",scenario:newerScenario,entry:known.entry,day:day)])
        let (session,player,controller)=try makeSession(try state(training:.object(record)),store:StateStore(directory:directory)){_ in};defer{player.shutdown()}
        let tools=TrainingTools(session:session,controller:controller)
        let listed=try await tools.call("list_training_entries",args:[:],lease:"lease"),list=try XCTUnwrap(listed as? [String:Any])
        XCTAssertEqual(list["keptForNewerVersion"] as? [String:AnyHashable],["activeAttempt":true,"suggestions":1])
        XCTAssertTrue(list["resumableEntryId"] is NSNull)
    }
}
private extension JSONValue {
    /// This attempt's JSON with `scenario` in place of its own.
    func replacingScenario(_ scenario:JSONValue)->JSONValue {guard case .object(var fields)=self else{return self};fields["scenario"]=scenario;return .object(fields)}
}
