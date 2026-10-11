import Foundation
import CryptoKit
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
    static func merged(_ written:[String:Any],_ unknown:[String:JSONValue])->[String:Any] {
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
public final class StateStore {
    public let directory:URL
    public var url:URL {directory.appendingPathComponent("state-v1.json")}
    public init(directory:URL){self.directory=directory}
    /// The largest state file or archive the app reads back; nothing larger is written as a save or an export.
    public static let maximumBytes=4*1024*1024
    public static func dataDirectoryIdentifier(bundleIdentifier:String?)->String {
        bundleIdentifier == "ai.xiaolai.checkmate" ? "ai.xiaolai.checkmate" : "ai.xiaolai.checkmate.native-development"
    }
    public static func defaultDirectory()->URL {
        if let path=ProcessInfo.processInfo.environment["CHECKMATE_DATA_DIR"] {return URL(fileURLWithPath:path)}
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent(dataDirectoryIdentifier(bundleIdentifier:Bundle.main.bundleIdentifier))
    }
    public func load() throws -> ApplicationState {
        guard FileManager.default.fileExists(atPath:url.path) else{return ApplicationState()}
        let data=try Data(contentsOf:url);guard data.count<=Self.maximumBytes else{throw CheckmateError.invalid("Saved state is too large.")}
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],object["schemaVersion"] as? Int == 1 else{throw CheckmateError.invalid("Unsupported saved-state version. Export or restore a backup.")}
        let value=try JSONDecoder().decode(ApplicationState.self,from:data)
        try Self.validate(value)
        return value
    }
    public static func validate(_ value:ApplicationState) throws {
        guard value.course.step>=0,(value.course.positions?.count ?? 0)<=1000,value.puzzles.values.allSatisfy({$0.attempts>=0}) else{throw CheckmateError.invalid("Saved learning progress has invalid bounds.")}
        if let games=value.miniGames {
            guard games.count<=MiniGameKind.allCases.count else{throw CheckmateError.invalid("Too many saved mini-games.")}
            for (id,game) in games {
                guard id==game.kind.rawValue,game.history.count<=MiniGameState.maximumHistory else{throw CheckmateError.invalid("Invalid mini-game history.")}
                let allowedPieces=Set(game.kind.initialBoard.values)
                for snapshot in game.history+[game.snapshot] {
                    guard ["w","b"].contains(snapshot.turn),(0...MiniGameRules.corners.count).contains(snapshot.cornerIndex),snapshot.pendingFinish==nil || ["w","b"].contains(snapshot.pendingFinish!),snapshot.board.count<=64,snapshot.board.allSatisfy({allowedPieces.contains($0.value) && ChessRules.validSquare($0.key) && $0.value.range(of:"^[wb][pnbrqk]$",options:.regularExpression) != nil}),snapshot.lastMove==nil || ChessRules.validSquare(snapshot.lastMove!.from) && ChessRules.validSquare(snapshot.lastMove!.to) else{throw CheckmateError.invalid("Invalid mini-game position.")}
                }
            }
        }
        guard value.schemaVersion==1 else{throw CheckmateError.invalid("Unsupported saved-state version.")}
        // A saved or imported game, current or previous, starts from a legal position and stays within the length the app can replay.
        let rules=try ChessRules()
        func replay(_ pgn:String,_ name:String)throws {try rules.restore(pgn);_ = try PGNImporter.validateFEN(rules.records.first?.before ?? rules.fen);guard rules.records.count<=ReviewPolicy.maximumMainlinePlies else{throw CheckmateError.invalid("The \(name) is longer than 2000 moves.")}}
        if !value.practice.pgn.isEmpty {try replay(value.practice.pgn,"saved game")};if !value.practice.fen.isEmpty,value.practice.fen != rules.fen{throw CheckmateError.invalid("Saved game checksum does not match its history.")}
        // Take Back's boundary lies within its game, or Take Back stays disabled until play passes it.
        guard value.practice.startPly<=rules.records.count else{throw CheckmateError.invalid("The saved game's practice start is beyond its moves.")}
        if !value.practice.previousGame.isEmpty{try replay(value.practice.previousGame,"previous game")}
        guard value.practice.previousStartPly<=(value.practice.previousGame.isEmpty ? 0:rules.records.count) else{throw CheckmateError.invalid("The previous game's practice start is beyond its moves.")}
    }
    public func save(_ state:ApplicationState) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data=try Self.encoded(state,tooLarge:"Saved state is too large.")  // load() refuses larger files
        if FileManager.default.fileExists(atPath:url.path) {let old=try Data(contentsOf:url);try old.write(to:directory.appendingPathComponent("state-v1.backup.json"),options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:directory.appendingPathComponent("state-v1.backup.json").path)}
        try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        guard try Data(contentsOf:url)==data else{throw CheckmateError.unavailable("Saved state read-back failed.")}
    }
    public func preserveBeforeImport(_ state:ApplicationState)throws -> URL {try Self.validate(state);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let archive=directory.appendingPathComponent("state-before-import-"+UUID().uuidString+".json");try Self.serialized(state).write(to:archive,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:archive.path);pruneImportBackups();return archive}
    /// Imports and practice forks each keep a backup; only the newest are kept so they never grow without bound.
    public static let keptImportBackups=20
    private func pruneImportBackups(){
        let files=((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey])) ?? []).filter{$0.lastPathComponent.hasPrefix("state-before-import-")}
        func modified(_ url:URL)->Date {(try? url.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate ?? .distantPast}
        let newestFirst=files.sorted{modified($0)>modified($1)}
        for old in newestFirst.dropFirst(Self.keptImportBackups){try? FileManager.default.removeItem(at:old)}
    }
    public var backupURL:URL{directory.appendingPathComponent("state-v1.backup.json")}
    /// Permanent copy of the state this app version first found on disk (the pre-upgrade state
    /// for an upgrade), written once before any write. The rolling backup above changes on every save.
    /// One copy per app version: every upgrade keeps the state that version first found, not only the first install.
    public var appVersion:String=Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unversioned"
    public var firstLaunchBackupURL:URL{directory.appendingPathComponent("state-v1.first-launch-\(appVersion.filter{$0.isLetter || $0.isNumber || $0=="."}).json")}
    public func preserveFirstLaunchBackup(){
        guard !FileManager.default.fileExists(atPath:firstLaunchBackupURL.path),let data=try? Data(contentsOf:url),data.count<=Self.maximumBytes else{return}
        do{try data.write(to:firstLaunchBackupURL,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:firstLaunchBackupURL.path)}catch{NativeLog.storage.error("First-launch backup could not be written")}
    }
    public func restoreBackup()throws {
        let data=try Data(contentsOf:backupURL);guard data.count<=Self.maximumBytes else{throw CheckmateError.invalid("Backup too large")};let value=try JSONDecoder().decode(ApplicationState.self,from:data);try Self.validate(value)
        if FileManager.default.fileExists(atPath:url.path){let preserved=directory.appendingPathComponent("state-preserved-"+UUID().uuidString+".json");try Data(contentsOf:url).write(to:preserved,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:preserved.path)}
        try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    public func export(to destination:URL) throws {try Data(contentsOf:url).write(to:destination,options:.atomic)}
    /// Writes `state` itself rather than the last saved file, so an export still works when saving does not.
    public func exportState(_ state:ApplicationState,to destination:URL) throws {
        try Self.encoded(state,tooLarge:"The progress is too large to export.").write(to:destination,options:.atomic)  // import refuses larger archives
    }
    /// The validated, timestamped bytes of `state` as saved and exported, proven to decode and within the size limit.
    private static func encoded(_ state:ApplicationState,tooLarge:String)throws -> Data {
        try validate(state);var value=state;value.savedAt=Date()
        let data=try serialized(value);_ = try JSONDecoder().decode(ApplicationState.self,from:data)
        guard data.count<=maximumBytes else{throw CheckmateError.invalid(tooLarge)};return data
    }
    /// The state's JSON with the fields a newer build wrote (`unknownFields`) kept.
    private static func serialized(_ state:ApplicationState)throws -> Data {
        guard let written=try JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as? [String:Any] else{throw CheckmateError.invalid("The state did not encode as an object.")}
        return try JSONSerialization.data(withJSONObject:ApplicationState.merged(written,state.unknownFields),options:[.sortedKeys,.prettyPrinted])
    }
    /// Start fresh after a launch failure: the unreadable file is kept beside the new state, never deleted.
    @discardableResult public func setAsideUnreadableState() throws -> URL {
        let kept=directory.appendingPathComponent("state-unreadable-"+UUID().uuidString+".json")
        try FileManager.default.moveItem(at:url,to:kept);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:kept.path);return kept
    }
}
