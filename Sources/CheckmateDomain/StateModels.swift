import Foundation
import CoreFoundation
public struct AppSettings:Codable,Equatable {
    public var coachReasoningEffort="minimal"
    public var coachVoice="cedar",voiceLanguage="en",voiceAutoConnect=true,voiceMicrophone=true,voiceInputDevice="",voiceAssistMoves=false,voiceVolume=1.0
    public var boardTheme="wood",narration=true,volume=1.0,autoAdvance=true,pieceDuration=700,moveSounds=true,effectsVolume=0.5,coachingMode="guided",skill=0,companionRole="coach"
    public var pauseForPractice=true
    public var lessonLanguage="en",lessonVoice="cedar"
    public var companionAutoStart=true
    public var opponentMode="skill",opponentElo=1320,miniOpponentProfile="standard",practiceSide="w"
    public var opponentPreset="custom",opponentRandomSeed=""
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
        coachReasoningEffort=choice("coachReasoningEffort",Self.reasoningEfforts,"minimal")
        coachVoice=choice("coachVoice",Self.voices,"cedar");voiceLanguage=choice("voiceLanguage",Array(Self.languages.keys),"en")
        let locale=raw["lessonLanguage"] as? String ?? "en"
        lessonLanguage=LessonLanguages.valid(locale) ? locale:"en"
        lessonVoice=choice("lessonVoice",["cedar","marin"],"cedar")
        boardTheme=choice("boardTheme",Array(Self.themes.keys),"wood");coachingMode=choice("coachingMode",["guided","on_request","quiet"],"guided");companionRole=choice("companionRole",["coach","opponent"],"coach")
        voiceAutoConnect=flag("voiceAutoConnect",true);companionAutoStart=flag("companionAutoStart",true);voiceMicrophone=flag("voiceMicrophone",true);voiceAssistMoves=flag("voiceAssistMoves",false)
        voiceInputDevice=String((raw["voiceInputDevice"] as? String ?? "").prefix(256));voiceVolume=level("voiceVolume",1)
        pauseForPractice=flag("pauseForPractice",true);narration=flag("narration",true);volume=level("volume",1);autoAdvance=flag("autoAdvance",true);moveSounds=flag("moveSounds",true);effectsVolume=level("effectsVolume",0.5)
        pieceDuration=[0,300,500,700].contains(integer("pieceDuration",-1)) ? integer("pieceDuration",700):700
        skill=max(0,min(20,integer("skill",0)))
        opponentPreset=choice("opponentPreset",["first_steps","gentle","club","custom"],"custom");let seed=raw["opponentRandomSeed"] as? String ?? "";opponentRandomSeed=UInt64(seed,radix:16) != nil ? seed:""
        opponentMode=choice("opponentMode",["skill","elo","beginner"],"skill");opponentElo=integer("opponentElo",1320);miniOpponentProfile=choice("miniOpponentProfile",["beginner","standard","challenging"],"standard");practiceSide=choice("practiceSide",["w","b"],"w")
    }
    public init(from decoder:Decoder) throws {
        let container=try decoder.singleValueContainer();let object=try container.decode([String:JSONValue].self)
        self.init(raw:object.mapValues(\.any))
    }
}
public enum JSONValue:Codable,Equatable {
    case null,bool(Bool),number(Double),string(String),array([JSONValue]),object([String:JSONValue])
    public init(from decoder:Decoder) throws {let c=try decoder.singleValueContainer();if c.decodeNil(){self = .null}else if let b=try? c.decode(Bool.self){self = .bool(b)}else if let n=try? c.decode(Double.self){self = .number(n)}else if let s=try? c.decode(String.self){self = .string(s)}else if let a=try? c.decode([JSONValue].self){self = .array(a)}else{self = .object(try c.decode([String:JSONValue].self))}}
    public func encode(to encoder:Encoder) throws {var c=encoder.singleValueContainer();switch self{case .null:try c.encodeNil();case .bool(let v):try c.encode(v);case .number(let v):try c.encode(v);case .string(let v):try c.encode(v);case .array(let v):try c.encode(v);case .object(let v):try c.encode(v)}}
    public var any:Any {switch self{case .null:return NSNull();case .bool(let v):return v;case .number(let v):return v;case .string(let v):return v;case .array(let v):return v.map(\.any);case .object(let v):return v.mapValues(\.any)}}
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
public struct CourseProgress:Codable {public var lessonID="intro",step=0,segmentID:String?,positions:[String:String]?,completed:[String]=[],answered:[String]=[];public init(){}}
public struct PuzzleProgress:Codable,Equatable {public var solved=false,review=false,attempts=0;public init(){};public mutating func record(correct:Bool,revealed:Bool=false){solved = solved || correct && !revealed;review = !correct || revealed;attempts+=1}}
public struct WindowState:Codable {public var left=false,right=false,settingsCategory="board";public var frame:[Double]?;public init(){}}
public struct ApplicationState:Codable {
    public var schemaVersion=1,savedAt=Date(),practice=PracticeState(),course=CourseProgress(),settings=AppSettings(),puzzles:[String:PuzzleProgress]=[:],window=WindowState(),importedArchives:[String]=[]
    public var miniGames:[String:MiniGameState]?
    public var puzzleFilters:[String:String]?
    /// Fields a newer build wrote that this one does not know (PL2-11), written back unchanged so a downgrade and a
    /// re-upgrade lose nothing. Fixed at decoding: a key this build writes stays this build's to change or remove.
    public var unknownFields:[String:JSONValue]=[:]
    public init(){}
    private enum CodingKeys:String,CodingKey {case schemaVersion,savedAt,practice,course,settings,puzzles,window,importedArchives,miniGames,puzzleFilters}
    /// The objects whose own unknown keys are kept as well; other values (puzzles, positions) are this build's records.
    static let preservedObjects:Set<String>=["practice","course","settings","window","miniGames"]
    /// Every key this build can write, from a state with each optional field present.
    private static let writable:[String:JSONValue]={
        var probe=ApplicationState();probe.miniGames=[:];probe.puzzleFilters=[:];probe.window.frame=[0,0,1,1];probe.course.segmentID="";probe.course.positions=[:]
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
    /// `written` (this build's JSON object of the state) with the unknown fields added back where this build wrote nothing.
    public static func merged(_ written:[String:Any],_ unknown:[String:JSONValue])->[String:Any] {
        var out=written
        for (key,value) in unknown {
            if preservedObjects.contains(key),case .object(let inner)=value,var mine=out[key] as? [String:Any] {for (field,v) in inner where mine[field]==nil{mine[field]=v.any};out[key]=mine}
            else if out[key]==nil{out[key]=value.any}
        }
        return out
    }
    private struct GameKey:CodingKey {let stringValue:String;var intValue:Int? {nil};init(stringValue:String){self.stringValue=stringValue};init?(intValue:Int){nil}}
    /// Field by field as before; only a mini-game this version does not know (saved by a newer one) is dropped
    /// instead of failing the whole saved state. A damaged mini-game this version knows fails it, so a later save
    /// never erases that progress unseen.
    public init(from decoder:Decoder)throws {
        let raw=try decoder.singleValueContainer().decode([String:JSONValue].self)
        let c=try decoder.container(keyedBy:CodingKeys.self)
        schemaVersion=try c.decode(Int.self,forKey:.schemaVersion);savedAt=try c.decode(Date.self,forKey:.savedAt);practice=try c.decode(PracticeState.self,forKey:.practice);course=try c.decode(CourseProgress.self,forKey:.course)
        settings=try c.decode(AppSettings.self,forKey:.settings);puzzles=try c.decode([String:PuzzleProgress].self,forKey:.puzzles);window=try c.decode(WindowState.self,forKey:.window);importedArchives=try c.decode([String].self,forKey:.importedArchives)
        if c.contains(.miniGames),try !c.decodeNil(forKey:.miniGames) {let games=try c.nestedContainer(keyedBy:GameKey.self,forKey:.miniGames);var known:[String:MiniGameState]=[:];for key in games.allKeys where MiniGameKind(rawValue:key.stringValue) != nil {known[key.stringValue]=try games.decode(MiniGameState.self,forKey:key)};miniGames=known}
        puzzleFilters=try c.decodeIfPresent([String:String].self,forKey:.puzzleFilters)
        unknownFields=Self.unknown(in:raw,mine:try Self.jsonObject(self))
    }
}
