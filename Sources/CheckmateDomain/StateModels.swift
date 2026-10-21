import Foundation
import CoreFoundation
public struct AppSettings:Codable,Equatable {
    public var coachReasoningEffort="minimal"
    public var coachVoice="cedar",voiceLanguage="en",voiceAutoConnect=false,voiceMicrophone=true,voiceInputDevice="",voiceAssistMoves=false,voiceVolume=1.0
    /// The learner agreed, once, to what the voice coach sends to OpenAI. Nothing connects voice before it, on launch
    /// or otherwise. A new install starts without it. Settings saved before this key existed take it from
    /// `voiceAutoConnect`: connecting at launch was on by default then, so most of those installs never chose it, but
    /// the owner decided that an existing install with it on keeps connecting at launch as it did before.
    public var voiceConsent=false
    /// The language transcription listens for: "auto" detects it, "response" uses the coach's response language.
    public var voiceInputLanguage="auto"
    public var boardTheme="wood",narration=true,volume=1.0,autoAdvance=true,pieceDuration=700,moveSounds=true,effectsVolume=0.5,coachingMode="guided",skill=0,companionRole="coach"
    public var pauseForPractice=true
    /// Opening a review analyzes the whole game, apart from positions already stored (R-4).
    public var reviewAutoAnalyze=true
    public var lessonLanguage="en",lessonVoice="cedar"
    public var companionAutoStart=true
    public var opponentMode="skill",opponentElo=1320,miniOpponentProfile="standard",practiceSide="w"
    public var opponentPreset="custom",opponentRandomSeed=""
    /// The learner's opponent level per mini-game, by kind; a game without one uses `miniOpponentProfile`. A new run
    /// freezes the level `MiniGameOffering` resolves from both, so changing them never changes a game in progress.
    public var miniOpponentProfiles:[String:String]=[:]
    /// The learner's opponent level per standard-rule training entry, by entry id (mini-game plan D4). A new attempt
    /// freezes the level `MiniGameOffering` resolves from it. Absent until the learner first chooses one, so a save
    /// without position games writes nothing new.
    public var positionGameLevels:[String:String]?
    public static let languages=["en":"English","zh":"Mandarin Chinese","es":"Spanish","fr":"French","de":"German","ja":"Japanese","ko":"Korean","pt":"Portuguese","it":"Italian","ar":"Arabic","hi":"Hindi"]
    public static let reasoningEfforts=["minimal","low","medium","high","xhigh"]
    public static let voices=["marin","cedar","alloy","ash","ballad","coral","echo","sage","shimmer","verse"]
    public static let themes=["wood":"Walnut","green":"Sage","blue":"Slate","neutral":"Graphite"]
    public init() {}
    public init(raw:[String:Any]) {
        func choice(_ k:String,_ allowed:[String],_ fallback:String)->String {let v=raw[k] as? String ?? fallback;return allowed.contains(v) ? v:fallback}
        func flag(_ k:String,_ fallback:Bool)->Bool {guard let n=raw[k] as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{return fallback};return n.boolValue}
        func integer(_ k:String,_ fallback:Int)->Int{guard let value=raw[k] as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID() else{return fallback};let n=value.doubleValue;guard n.isFinite,floor(n)==n,abs(n)<=1_000_000 else{return fallback};return Int(n)}
        func level(_ k:String,_ fallback:Double)->Double {guard let v=raw[k] as? NSNumber,CFGetTypeID(v) != CFBooleanGetTypeID(),v.doubleValue.isFinite else{return fallback};return max(0,min(1,v.doubleValue))}
        // A fresh value's defaults are the fallbacks, so a missing or invalid key reads exactly as a new setting.
        let d=AppSettings()
        coachReasoningEffort=choice("coachReasoningEffort",Self.reasoningEfforts,d.coachReasoningEffort)
        coachVoice=choice("coachVoice",Self.voices,d.coachVoice);voiceLanguage=choice("voiceLanguage",Array(Self.languages.keys),d.voiceLanguage)
        let locale=raw["lessonLanguage"] as? String ?? d.lessonLanguage
        lessonLanguage=LessonLanguages.valid(locale) ? locale:d.lessonLanguage
        lessonVoice=choice("lessonVoice",["cedar","marin"],d.lessonVoice)
        boardTheme=choice("boardTheme",Array(Self.themes.keys),d.boardTheme);coachingMode=choice("coachingMode",["guided","on_request","quiet"],d.coachingMode);companionRole=choice("companionRole",["coach","opponent"],d.companionRole)
        voiceAutoConnect=flag("voiceAutoConnect",d.voiceAutoConnect);voiceConsent=raw["voiceConsent"]==nil ? voiceAutoConnect:flag("voiceConsent",d.voiceConsent);companionAutoStart=flag("companionAutoStart",d.companionAutoStart);voiceMicrophone=flag("voiceMicrophone",d.voiceMicrophone);voiceAssistMoves=flag("voiceAssistMoves",d.voiceAssistMoves)
        voiceInputDevice=String((raw["voiceInputDevice"] as? String ?? d.voiceInputDevice).prefix(256));voiceVolume=level("voiceVolume",d.voiceVolume);voiceInputLanguage=choice("voiceInputLanguage",["auto","response"],d.voiceInputLanguage)
        reviewAutoAnalyze=flag("reviewAutoAnalyze",d.reviewAutoAnalyze)
        pauseForPractice=flag("pauseForPractice",d.pauseForPractice);narration=flag("narration",d.narration);volume=level("volume",d.volume);autoAdvance=flag("autoAdvance",d.autoAdvance);moveSounds=flag("moveSounds",d.moveSounds);effectsVolume=level("effectsVolume",d.effectsVolume)
        pieceDuration=[0,300,500,700].contains(integer("pieceDuration",-1)) ? integer("pieceDuration",d.pieceDuration):d.pieceDuration
        skill=max(0,min(20,integer("skill",d.skill)))
        opponentPreset=choice("opponentPreset",["first_steps","gentle","club","custom"],d.opponentPreset);let seed=raw["opponentRandomSeed"] as? String ?? d.opponentRandomSeed;opponentRandomSeed=UInt64(seed,radix:16) != nil ? seed:d.opponentRandomSeed
        opponentMode=choice("opponentMode",["skill","elo","beginner"],d.opponentMode);opponentElo=integer("opponentElo",d.opponentElo);miniOpponentProfile=choice("miniOpponentProfile",MiniOpponentPolicy.profiles,d.miniOpponentProfile);practiceSide=choice("practiceSide",["w","b"],d.practiceSide)
        // Entry by entry like `choice`: an unknown game, a solo game or an unknown profile is dropped, the rest kept.
        miniOpponentProfiles=(raw["miniOpponentProfiles"] as? [String:Any] ?? [:]).reduce(into:[:]){kept,entry in if let kind=MiniGameKind(rawValue:entry.key),!kind.solo,let profile=entry.value as? String,MiniOpponentPolicy.profiles.contains(profile){kept[entry.key]=profile}}
        // The same, by entry: an invalid entry id or an unknown level is dropped, the rest kept.
        positionGameLevels=(raw["positionGameLevels"] as? [String:Any]).map{$0.reduce(into:[:]){kept,entry in if entry.key.count<=48,entry.key.range(of:TrainingEntryDefinition.idPattern,options:.regularExpression) != nil,let level=entry.value as? String,TrainingOpponentLevel(rawValue:level) != nil{kept[entry.key]=level}}}
    }
    public init(from decoder:Decoder) throws {
        let container=try decoder.singleValueContainer();let object=try container.decode([String:JSONValue].self)
        self.init(raw:object.mapValues(\.any))
    }
}
/// Any JSON value. A 64-bit whole number a `Double` cannot hold exactly (beyond 2^53) is kept as `integer`, or as
/// `unsigned` above `Int64.max`, so it is written back unchanged; every other number is `number`.
public enum JSONValue:Codable,Equatable {
    case null,bool(Bool),number(Double),string(String),array([JSONValue]),object([String:JSONValue])
    case integer(Int64),unsigned(UInt64)
    public init(from decoder:Decoder) throws {let c=try decoder.singleValueContainer();if c.decodeNil(){self = .null}else if let b=try? c.decode(Bool.self){self = .bool(b)}else if let i=try? c.decode(Int64.self),Double(exactly:i)==nil{self = .integer(i)}else if let u=try? c.decode(UInt64.self),Double(exactly:u)==nil{self = .unsigned(u)}else if let n=try? c.decode(Double.self){self = .number(n)}else if let s=try? c.decode(String.self){self = .string(s)}else if let a=try? c.decode([JSONValue].self){self = .array(a)}else{self = .object(try c.decode([String:JSONValue].self))}}
    public func encode(to encoder:Encoder) throws {var c=encoder.singleValueContainer();switch self{case .null:try c.encodeNil();case .bool(let v):try c.encode(v);case .number(let v):try c.encode(v);case .integer(let v):try c.encode(v);case .unsigned(let v):try c.encode(v);case .string(let v):try c.encode(v);case .array(let v):try c.encode(v);case .object(let v):try c.encode(v)}}
    public var any:Any {switch self{case .null:return NSNull();case .bool(let v):return v;case .number(let v):return v;case .integer(let v):return v;case .unsigned(let v):return v;case .string(let v):return v;case .array(let v):return v.map(\.any);case .object(let v):return v.mapValues(\.any)}}
}
public struct PracticeEnding:Codable,Equatable {public var result:String,reason:String;public init(result:String,reason:String){self.result=result;self.reason=reason}}
public struct PracticeState:Codable {
    public var pgn="",fen="",previousGame="",beginnerSevereStreak=0
    /// The side the learner played in `previousGame`; saves before it was recorded were White games.
    public var previousSide="w"
    /// A game ended by resignation or a claimed draw (the rules alone never end it); nil while it continues.
    public var ending:PracticeEnding?
    /// Moves before this ply came with a practice fork (the reviewed game); Take Back never rewinds into them.
    public var startPly=0
    /// `ending` and `startPly` of `previousGame`, so a restored game keeps its result and its Take Back boundary.
    public var previousEnding:PracticeEnding?,previousStartPly=0
    public init(){}
    private enum CodingKeys:String,CodingKey {case pgn,fen,previousGame,beginnerSevereStreak,previousSide,ending,startPly,previousEnding,previousStartPly}
    private static func decided(_ ending:PracticeEnding?)->PracticeEnding? {ending.flatMap{["1-0","0-1","1/2-1/2"].contains($0.result) ? $0:nil}}
    public init(from decoder:Decoder)throws {let c=try decoder.container(keyedBy:CodingKeys.self);pgn=try c.decodeIfPresent(String.self,forKey:.pgn) ?? "";fen=try c.decodeIfPresent(String.self,forKey:.fen) ?? "";previousGame=try c.decodeIfPresent(String.self,forKey:.previousGame) ?? "";previousSide=(try? c.decodeIfPresent(String.self,forKey:.previousSide)).flatMap{["w","b"].contains($0) ? $0:nil} ?? "w";beginnerSevereStreak=max(0,min(BeginnerPolicy.maximumConsecutiveSevereErrors,try c.decodeIfPresent(Int.self,forKey:.beginnerSevereStreak) ?? 0));startPly=max(0,(try? c.decodeIfPresent(Int.self,forKey:.startPly)).flatMap{$0} ?? 0);ending=Self.decided((try? c.decodeIfPresent(PracticeEnding.self,forKey:.ending)).flatMap{$0});previousStartPly=max(0,(try? c.decodeIfPresent(Int.self,forKey:.previousStartPly)).flatMap{$0} ?? 0);previousEnding=Self.decided((try? c.decodeIfPresent(PracticeEnding.self,forKey:.previousEnding)).flatMap{$0})}
}
/// `edition` is the course edition the progress refers to; progress saved without one is edition 1 and is carried
/// forward by `ProgressMigration` as it loads.
/// `completed` lists lessons explored to their end; `practised`, lessons whose own exercise was done at least once;
/// `unaided`, those whose exercise was done at least once in an attempt with no hint shown (absent in older saves).
public struct CourseProgress:Codable {public var lessonID="intro",step=0,segmentID:String?,positions:[String:String]?,completed:[String]=[],answered:[String]=[],edition:Int?=ProgressMigration.courseEdition,practised:[String]?,unaided:[String]?;public init(){}}
/// One puzzle's progress. `attempts` counts the learner's answers, one per answer.
public struct PuzzleProgress:Codable,Equatable {
    /// The most attempts a loaded or imported record may hold (`StateStore.validate` refuses more): the bound every
    /// persisted progress counter shares.
    public static let maximumAttempts=TrainingState.maximumCount
    /// `solved`: answered correctly with no mistake and no reveal in one visit.
    public var solved=false,review=false,attempts=0;public init(){}
    /// Whether the record's very first answer was correct and not revealed; nil in records saved before it was kept.
    public var firstTry:Bool?
    /// Answered correctly after a mistake in the same visit: worked out, but not first time, so `solved` stays false.
    public var solvedLater:Bool?
    /// Solved with the first answer ever given. An older record without `firstTry` claims it only when its one answer
    /// was correct; with more answers the first is unknown, so it is not claimed.
    public var solvedFirstTime:Bool {firstTry ?? (solved && attempts==1)}
    /// Records one answer. The count saturates at `maximumAttempts`: a record loaded at the bound stays at the bound
    /// rather than leaving the range `StateStore.validate` accepts, which would refuse every later save. A count above
    /// the bound (never loaded, only constructed) is pulled back to it, and the arithmetic cannot overflow.
    /// `afterMistake`: an earlier answer in this visit was wrong, so a correct one is a later solve.
    public mutating func record(correct:Bool,revealed:Bool=false,afterMistake:Bool=false){
        if attempts==0{firstTry=correct && !revealed && !afterMistake}
        if correct && afterMistake && !revealed{solvedLater=true}
        solved = solved || correct && !revealed && !afterMistake;review = !correct || revealed || afterMistake;attempts=attempts<Self.maximumAttempts ? attempts+1:Self.maximumAttempts
    }
}
public struct WindowState:Codable {public var left=false,right=false,settingsCategory="board";public var frame:[Double]?;public init(){}}
public struct ApplicationState:Codable {
    public var schemaVersion=1,savedAt=Date(),practice=PracticeState(),course=CourseProgress(),settings=AppSettings(),puzzles:[String:PuzzleProgress]=[:],window=WindowState(),importedArchives:[String]=[]
    public var miniGames:[String:MiniGameState]?
    /// Each lesson's exercise in progress, by lesson id: separate from the practice game, mini-games and training.
    public var lessonAttempts:[String:LessonAttemptRecord]?
    public var puzzleFilters:[String:String]?
    /// Optional training progress with its own envelope version; schemaVersion stays 1 (plan: Data Model).
    public var training:TrainingState?
    /// A `training` object this build cannot use (unreadable, invalid or from a newer version), kept verbatim: it is
    /// written back exactly as read, ahead of any replacement, and training writes stay off until an explicit recovery.
    public var trainingRaw:JSONValue?
    /// Why `trainingRaw` was kept: `future` (a newer version, never overwritten here) or `unreadable`. Not saved.
    public var trainingIssue:String?
    /// Fields a newer build wrote that this one does not know (PL2-11), written back unchanged so a downgrade and a
    /// re-upgrade lose nothing. Fixed at decoding: a key this build writes stays this build's to change or remove.
    public var unknownFields:[String:JSONValue]=[:]
    /// Unknown fields deeper inside the records this build reads (a new field of a known mini-game), by path from the
    /// top. Written back only into a record that still exists, so a record this build removed is never revived as a stub.
    public var unknownNestedFields:[[String]:JSONValue]=[:]
    public init(){}
    private enum CodingKeys:String,CodingKey {case schemaVersion,savedAt,practice,course,settings,puzzles,window,importedArchives,miniGames,lessonAttempts,puzzleFilters,training}
    /// The objects whose own unknown keys are kept as well; other values (puzzles, positions) are this build's records.
    static let preservedObjects:Set<String>=["practice","course","settings","window","miniGames","training","lessonAttempts"]
    /// Every key this build can write, from a state with each optional field present.
    private static let writable:[String:JSONValue]={
        var probe=ApplicationState();probe.miniGames=[:];probe.lessonAttempts=[:];probe.course.practised=[];probe.course.unaided=[];probe.puzzleFilters=[:];probe.training=TrainingState();probe.window.frame=[0,0,1,1];probe.course.segmentID="";probe.course.positions=[:];probe.settings.positionGameLevels=[:]
        probe.practice.ending=PracticeEnding(result:"1-0",reason:"");probe.practice.previousEnding=probe.practice.ending
        return (try? jsonObject(probe)) ?? [:]
    }()
    private static func jsonObject(_ state:ApplicationState)throws -> [String:JSONValue] {try JSONDecoder().decode([String:JSONValue].self,from:JSONEncoder().encode(state))}
    /// The keys of `raw` that neither `mine` nor `writable` has, and within the preserved objects, theirs.
    private static func unknown(in raw:[String:JSONValue],mine:[String:JSONValue])->[String:JSONValue] {
        var kept:[String:JSONValue]=[:]
        for (key,value) in raw {
            guard mine[key] != nil || writable[key] != nil else{kept[key]=value;continue}
            guard preservedObjects.contains(key),case .object(let inner)=value else{continue}
            func object(_ v:JSONValue?)->[String:JSONValue] {if case .object(let o)=v{return o};return [:]}
            let theirs=inner.filter{object(mine[key])[$0.key]==nil && object(writable[key])[$0.key]==nil}
            if !theirs.isEmpty{kept[key] = .object(theirs)}
        }
        return kept
    }
    /// Below the first level of the preserved objects: the fields of `raw` that neither `mine` nor `writable` has, by
    /// path. A field this build knows is followed into when both sides are objects; arrays are this build's records.
    private static func nestedUnknown(in raw:[String:JSONValue],mine:[String:JSONValue])->[[String]:JSONValue] {
        func object(_ v:JSONValue?)->[String:JSONValue] {if case .object(let o)=v{return o};return [:]}
        var kept:[[String]:JSONValue]=[:]
        func collect(_ raw:[String:JSONValue],_ mine:[String:JSONValue],_ known:[String:JSONValue],_ path:[String]) {
            for (field,value) in raw {
                if mine[field]==nil && known[field]==nil{kept[path+[field]]=value}
                else if case .object(let inner)=value{collect(inner,object(mine[field]),object(known[field]),path+[field])}
            }
        }
        for key in preservedObjects {
            let ownMine=object(mine[key]),ownKnown=object(writable[key])
            for (field,value) in object(raw[key]) where ownMine[field] != nil || ownKnown[field] != nil {
                if case .object(let inner)=value{collect(inner,object(ownMine[field]),object(ownKnown[field]),[key,field])}
            }
        }
        return kept
    }
    /// `written` (this build's JSON object of the state) with the unknown fields added back where this build wrote nothing.
    /// A nested field (`unknownNestedFields`) goes back only into a record `written` still has.
    public static func merged(_ written:[String:Any],_ unknown:[String:JSONValue],nested:[[String]:JSONValue]=[:])->[String:Any] {
        var out=written
        for (key,value) in unknown {
            if preservedObjects.contains(key),case .object(let inner)=value,var mine=out[key] as? [String:Any] {for (field,v) in inner where mine[field]==nil{mine[field]=v.any};out[key]=mine}
            else if out[key]==nil{out[key]=value.any}
        }
        func inserted(_ value:JSONValue,at path:ArraySlice<String>,in object:[String:Any])->[String:Any] {
            guard let key=path.first else{return object}
            var result=object
            if path.count==1 {if result[key]==nil{result[key]=value.any}}
            else if let inner=result[key] as? [String:Any] {result[key]=inserted(value,at:path.dropFirst(),in:inner)}
            return result
        }
        for (path,value) in nested{out=inserted(value,at:path[...],in:out)}
        return out
    }
    /// Whether a saved training `version` is newer than this build's.
    private static func newer(_ version:JSONValue?)->Bool {
        switch version {case .number(let v)?:return v>Double(TrainingState.version);case .integer(let v)?:return v>Int64(TrainingState.version);case .unsigned(let v)?:return v>UInt64(TrainingState.version);default:return false}
    }
    /// Field by field as before; only a mini-game this version does not know (saved by a newer one) is dropped
    /// instead of failing the whole saved state. A damaged mini-game this version knows fails it, so a later save
    /// never erases that progress unseen.
    public init(from decoder:Decoder)throws {
        // Progress from an earlier course edition is renamed first, so every field below reads the current one.
        let raw=ProgressMigration.migrate(state:try decoder.singleValueContainer().decode([String:JSONValue].self))
        func field<T:Decodable>(_ key:CodingKeys,_ type:T.Type)throws -> T {
            guard let value=raw[key.rawValue] else{throw DecodingError.keyNotFound(key,.init(codingPath:decoder.codingPath,debugDescription:"Missing \(key.rawValue)."))}
            return try JSONDecoder().decode(type,from:JSONEncoder().encode(value))
        }
        schemaVersion=try field(.schemaVersion,Int.self);savedAt=try field(.savedAt,Date.self);practice=try field(.practice,PracticeState.self);course=try field(.course,CourseProgress.self)
        settings=try field(.settings,AppSettings.self);puzzles=try field(.puzzles,[String:PuzzleProgress].self);window=try field(.window,WindowState.self);importedArchives=try field(.importedArchives,[String].self)
        if case .object(let games)?=raw["miniGames"] {var known:[String:MiniGameState]=[:];for (key,game) in games where MiniGameKind(rawValue:key) != nil {known[key]=try JSONDecoder().decode(MiniGameState.self,from:JSONEncoder().encode(game))};miniGames=known}
        else if let games=raw["miniGames"],games != .null {throw DecodingError.typeMismatch([String:MiniGameState].self,.init(codingPath:decoder.codingPath,debugDescription:"Saved mini-games are not an object."))}
        // An attempt this build cannot read is left out on its own (kept raw in `unknownFields` and written back until
        // the learner plays that exercise here): the rest still loads.
        if case .object(let attempts)?=raw["lessonAttempts"] {var known:[String:LessonAttemptRecord]=[:];for (key,value) in attempts {if let record=try? JSONDecoder().decode(LessonAttemptRecord.self,from:JSONEncoder().encode(value)){known[key]=record}};lessonAttempts=known}
        if let filters=raw["puzzleFilters"],filters != .null {puzzleFilters=try JSONDecoder().decode([String:String].self,from:JSONEncoder().encode(filters))}
        // Bad or newer training data never prevents loading the rest: it is kept raw, never silently replaced.
        if let value=raw["training"],value != .null {
            do{let decoded=try JSONDecoder().decode(TrainingState.self,from:JSONEncoder().encode(value));try decoded.validate();guard try JSONEncoder().encode(decoded).count<=TrainingState.maximumBytes else{throw CheckmateError.invalid("Training progress exceeds its storage budget.")};training=decoded}
            catch{trainingRaw=value;if case .object(let object)=value,Self.newer(object["version"]){trainingIssue="future"}else{trainingIssue="unreadable"}}
        }
        let mine=try Self.jsonObject(self);unknownFields=Self.unknown(in:raw,mine:mine);unknownNestedFields=Self.nestedUnknown(in:raw,mine:mine)
    }
    public func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(schemaVersion,forKey:.schemaVersion);try c.encode(savedAt,forKey:.savedAt);try c.encode(practice,forKey:.practice);try c.encode(course,forKey:.course)
        try c.encode(settings,forKey:.settings);try c.encode(puzzles,forKey:.puzzles);try c.encode(window,forKey:.window);try c.encode(importedArchives,forKey:.importedArchives)
        try c.encodeIfPresent(miniGames,forKey:.miniGames);try c.encodeIfPresent(lessonAttempts,forKey:.lessonAttempts);try c.encodeIfPresent(puzzleFilters,forKey:.puzzleFilters)
        if let trainingRaw{try c.encode(trainingRaw,forKey:.training)}else{try c.encodeIfPresent(training,forKey:.training)}
    }
    /// Training records may be written: none was kept raw for lack of understanding.
    public var trainingWritable:Bool {trainingRaw==nil}
}
