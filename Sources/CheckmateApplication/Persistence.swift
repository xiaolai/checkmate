import CheckmateDomain
import CheckmateRules
import CheckmateContent
import CheckmateSupport
import CheckmateAssets
import Foundation
import CryptoKit
import CoreFoundation
public final class StateStore {
    public let directory:URL
    public var url:URL {directory.appendingPathComponent("state-v1.json")}
    public init(directory:URL){self.directory=directory}
    /// The largest state file or archive the app reads back; nothing larger is written as a save or an export.
    public static let maximumBytes=4*1024*1024
    public static func dataDirectoryIdentifier(bundleIdentifier:String?)->String {ApplicationDataPaths.dataDirectoryIdentifier(bundleIdentifier:bundleIdentifier)}
    public static func defaultDirectory()->URL {ApplicationDataPaths.defaultDirectory()}
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
