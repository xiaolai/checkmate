import Foundation
import CryptoKit
import CoreFoundation
public struct AppSettings:Codable,Equatable {
    public var coachVoice="cedar",voiceLanguage="en",voiceAutoConnect=true,voiceMicrophone=true,voiceInputDevice="",voiceAssistMoves=false,voiceVolume=1.0
    public var boardTheme="wood",narration=true,volume=1.0,autoAdvance=true,pieceDuration=700,moveSounds=true,effectsVolume=0.5,coachingMode="guided",skill=0,companionRole="coach"
    public var companionAutoStart=true
    public var opponentMode="skill",opponentElo=1320,miniOpponentProfile="standard",practiceSide="w"
    public var opponentPreset="custom",opponentRandomSeed=""
    public static let languages=["en":"English","zh":"Mandarin Chinese","es":"Spanish","fr":"French","de":"German","ja":"Japanese","ko":"Korean","pt":"Portuguese","it":"Italian","ar":"Arabic","hi":"Hindi"]
    public static let voices=["marin","cedar","alloy","ash","ballad","coral","echo","sage","shimmer","verse"]
    public static let themes=["wood":"Walnut","green":"Sage","blue":"Slate","neutral":"Graphite"]
    public init() {}
    public init(raw:[String:Any]) {
        func choice(_ k:String,_ allowed:[String],_ fallback:String)->String {let v=raw[k] as? String ?? fallback;return allowed.contains(v) ? v:fallback}
        func flag(_ k:String,_ fallback:Bool)->Bool {guard let n=raw[k] as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{return fallback};return n.boolValue}
        func integer(_ k:String,_ fallback:Int)->Int{guard let value=raw[k] as? NSNumber,CFGetTypeID(value) != CFBooleanGetTypeID() else{return fallback};let n=value.doubleValue;guard n.isFinite,floor(n)==n,abs(n)<=1_000_000 else{return fallback};return Int(n)}
        func level(_ k:String,_ fallback:Double)->Double {guard let v=raw[k] as? NSNumber,CFGetTypeID(v) != CFBooleanGetTypeID(),v.doubleValue.isFinite else{return fallback};return max(0,min(1,v.doubleValue))}
        coachVoice=choice("coachVoice",Self.voices,"cedar");voiceLanguage=choice("voiceLanguage",Array(Self.languages.keys),"en")
        boardTheme=choice("boardTheme",Array(Self.themes.keys),"wood");coachingMode=choice("coachingMode",["guided","on_request","quiet"],"guided");companionRole=choice("companionRole",["coach","opponent"],"coach")
        voiceAutoConnect=flag("voiceAutoConnect",true);companionAutoStart=flag("companionAutoStart",true);voiceMicrophone=flag("voiceMicrophone",true);voiceAssistMoves=flag("voiceAssistMoves",false)
        voiceInputDevice=String((raw["voiceInputDevice"] as? String ?? "").prefix(256));voiceVolume=level("voiceVolume",1)
        narration=flag("narration",true);volume=level("volume",1);autoAdvance=flag("autoAdvance",true);moveSounds=flag("moveSounds",true);effectsVolume=level("effectsVolume",0.5)
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
public struct PracticeState:Codable {
    public var pgn="",fen="",previousGame="",beginnerSevereStreak=0
    public init(){}
    private enum CodingKeys:String,CodingKey {case pgn,fen,previousGame,beginnerSevereStreak}
    public init(from decoder:Decoder)throws {let c=try decoder.container(keyedBy:CodingKeys.self);pgn=try c.decodeIfPresent(String.self,forKey:.pgn) ?? "";fen=try c.decodeIfPresent(String.self,forKey:.fen) ?? "";previousGame=try c.decodeIfPresent(String.self,forKey:.previousGame) ?? "";beginnerSevereStreak=max(0,min(BeginnerPolicy.maximumConsecutiveSevereErrors,try c.decodeIfPresent(Int.self,forKey:.beginnerSevereStreak) ?? 0))}
}
public struct CourseProgress:Codable {public var lessonID="intro",step=0,completed:[String]=[],answered:[String]=[];public init(){}}
public struct PuzzleProgress:Codable,Equatable {public var solved=false,review=false,attempts=0;public init(){};public mutating func record(correct:Bool,revealed:Bool=false){solved = solved || correct && !revealed;review = !correct || revealed;attempts+=1}}
public struct WindowState:Codable {public var left=false,right=false,settingsCategory="board";public var frame:[Double]?;public init(){}}
public struct ApplicationState:Codable {
    public var schemaVersion=1,savedAt=Date(),practice=PracticeState(),course=CourseProgress(),settings=AppSettings(),puzzles:[String:PuzzleProgress]=[:],window=WindowState(),importedArchives:[String]=[]
    public var miniGames:[String:MiniGameState]?
    public var puzzleFilters:[String:String]?
    public init(){}
}
public final class StateStore {
    public let directory:URL
    public var url:URL {directory.appendingPathComponent("state-v1.json")}
    public init(directory:URL){self.directory=directory}
    public static func dataDirectoryIdentifier(bundleIdentifier:String?)->String {
        bundleIdentifier == "ai.xiaolai.checkmate" ? "ai.xiaolai.checkmate" : "ai.xiaolai.checkmate.native-development"
    }
    public static func defaultDirectory()->URL {
        if let path=ProcessInfo.processInfo.environment["CHECKMATE_DATA_DIR"] {return URL(fileURLWithPath:path)}
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent(dataDirectoryIdentifier(bundleIdentifier:Bundle.main.bundleIdentifier))
    }
    public func load() throws -> ApplicationState {
        guard FileManager.default.fileExists(atPath:url.path) else{return ApplicationState()}
        let data=try Data(contentsOf:url);guard data.count<=4*1024*1024 else{throw CheckmateError.invalid("Saved state is too large.")}
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],object["schemaVersion"] as? Int == 1 else{throw CheckmateError.invalid("Unsupported saved-state version. Export or restore a backup.")}
        let value=try JSONDecoder().decode(ApplicationState.self,from:data)
        try Self.validate(value)
        return value
    }
    public static func validate(_ value:ApplicationState) throws {
        guard value.course.step>=0,value.puzzles.values.allSatisfy({$0.attempts>=0}) else{throw CheckmateError.invalid("Saved learning progress has invalid bounds.")}
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
        let rules=try ChessRules();if !value.practice.pgn.isEmpty {try rules.restore(value.practice.pgn)};if !value.practice.fen.isEmpty,value.practice.fen != rules.fen{throw CheckmateError.invalid("Saved game checksum does not match its history.")}
        if !value.practice.previousGame.isEmpty{try rules.restore(value.practice.previousGame)}
    }
    public func save(_ state:ApplicationState) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try Self.validate(state);var value=state;value.savedAt=Date();let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
        let data=try encoder.encode(value);_ = try JSONDecoder().decode(ApplicationState.self,from:data)
        if FileManager.default.fileExists(atPath:url.path) {let old=try Data(contentsOf:url);try old.write(to:directory.appendingPathComponent("state-v1.backup.json"),options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:directory.appendingPathComponent("state-v1.backup.json").path)}
        try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        guard try Data(contentsOf:url)==data else{throw CheckmateError.unavailable("Saved state read-back failed.")}
    }
    public func preserveBeforeImport(_ state:ApplicationState)throws -> URL {try Self.validate(state);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let archive=directory.appendingPathComponent("state-before-import-"+UUID().uuidString+".json");try JSONEncoder().encode(state).write(to:archive,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:archive.path);return archive}
    public var backupURL:URL{directory.appendingPathComponent("state-v1.backup.json")}
    /// Permanent copy of the state this app version first found on disk (the pre-upgrade state
    /// for an upgrade), written once before any write. The rolling backup above changes on every save.
    public var firstLaunchBackupURL:URL{directory.appendingPathComponent("state-v1.first-launch-backup.json")}
    public func preserveFirstLaunchBackup(){
        guard !FileManager.default.fileExists(atPath:firstLaunchBackupURL.path),let data=try? Data(contentsOf:url),data.count<=4*1024*1024 else{return}
        do{try data.write(to:firstLaunchBackupURL,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:firstLaunchBackupURL.path)}catch{NativeLog.storage.error("First-launch backup could not be written")}
    }
    public func restoreBackup()throws {
        let data=try Data(contentsOf:backupURL);guard data.count<=4*1024*1024 else{throw CheckmateError.invalid("Backup too large")};let value=try JSONDecoder().decode(ApplicationState.self,from:data);try Self.validate(value)
        if FileManager.default.fileExists(atPath:url.path){let preserved=directory.appendingPathComponent("state-preserved-"+UUID().uuidString+".json");try Data(contentsOf:url).write(to:preserved,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:preserved.path)}
        try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    public func export(to destination:URL) throws {try Data(contentsOf:url).write(to:destination,options:.atomic)}
}
