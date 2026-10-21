import CheckmateDomain
import CheckmateRules
import CheckmateSupport
import Foundation
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
        let data=try Self.read(url,tooLarge:"Saved state is too large.")
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any],object["schemaVersion"] as? Int == 1 else{throw CheckmateError.invalid("Unsupported saved-state version. Export or restore a backup.")}
        let value=try JSONDecoder().decode(ApplicationState.self,from:data)
        try Self.validate(value)
        return value
    }
    public static func validate(_ value:ApplicationState) throws {
        guard value.course.step>=0,(value.course.positions?.count ?? 0)<=1000,value.puzzles.values.allSatisfy({(0...PuzzleProgress.maximumAttempts).contains($0.attempts)}) else{throw CheckmateError.invalid("Saved learning progress has invalid bounds.")}
        if let games=value.miniGames {
            guard games.count<=MiniGameKind.allCases.count else{throw CheckmateError.invalid("Too many saved mini-games.")}
            for (id,game) in games {
                guard id==game.kind.rawValue,game.history.count<=MiniGameState.maximumHistory else{throw CheckmateError.invalid("Invalid mini-game history.")}
                let allowedPieces=Set(game.kind.initialBoard.values)
                for snapshot in game.history+[game.snapshot] {
                    guard ["w","b"].contains(snapshot.turn),(0...MiniGameRules.corners.count).contains(snapshot.cornerIndex),snapshot.pendingFinish==nil || ["w","b"].contains(snapshot.pendingFinish!),snapshot.board.count<=64,snapshot.board.allSatisfy({allowedPieces.contains($0.value) && ChessRules.validSquare($0.key)}),snapshot.lastMove==nil || ChessRules.validSquare(snapshot.lastMove!.from) && ChessRules.validSquare(snapshot.lastMove!.to) else{throw CheckmateError.invalid("Invalid mini-game position.")}
                }
            }
        }
        // Lesson attempts are replayed against their lesson when opened; here only their size and shape are bounded.
        guard [value.course.practised,value.course.unaided].allSatisfy({($0?.count ?? 0)<=200 && ($0 ?? []).allSatisfy{!$0.isEmpty && $0.count<=80}}) else{throw CheckmateError.invalid("Saved lesson exercises have invalid bounds.")}
        guard (value.course.exercises?.count ?? 0)<=200,(value.course.exercises ?? [:]).allSatisfy({!$0.key.isEmpty && $0.key.count<=80 && $0.value.hints.map{(0...3).contains($0)} ?? true}),value.puzzles.values.allSatisfy({$0.hints.map{(0...PuzzleProgress.maximumHints).contains($0)} ?? true}) else{throw CheckmateError.invalid("Saved lesson exercises have invalid bounds.")}
        if let attempts=value.lessonAttempts {
            guard attempts.count<=200,attempts.allSatisfy({!$0.key.isEmpty && $0.key.count<=80 && $0.value.moves.count<=LessonAttemptRecord.maximumMoves && $0.value.moves.allSatisfy(ChessRules.validUCI) && (0...3).contains($0.value.hints) && $0.value.id.count<=64 && $0.value.definition.count<=64}) else{throw CheckmateError.invalid("Saved lesson exercises have invalid bounds.")}
        }
        // This build's own training record stays within its bounds; a raw kept record is written back unchanged.
        if let training=value.training,value.trainingWritable {try training.validate();guard try JSONEncoder().encode(training).count<=TrainingState.maximumBytes else{throw CheckmateError.invalid("Training progress exceeds its storage budget.")}}
        guard value.schemaVersion==1 else{throw CheckmateError.invalid("Unsupported saved-state version.")}
        // A saved or imported game, current or previous, starts from a legal position and stays within the length the app can replay.
        let rules=try ChessRules()
        // An over-long game is refused from its text before it is replayed; the history is read once and gives its ply count.
        func replay(_ pgn:String,_ name:String)throws -> Int {let tooLong=CheckmateError.invalid("The \(name) is longer than 2000 moves.");guard mainlineMoveCount(pgn)<=ReviewPolicy.maximumMainlinePlies else{throw tooLong};try rules.restore(pgn);let records=rules.records;_ = try PGNImporter.validateFEN(records.first?.before ?? rules.fen);guard records.count<=ReviewPolicy.maximumMainlinePlies else{throw tooLong};return records.count}
        let plies=value.practice.pgn.isEmpty ? 0:try replay(value.practice.pgn,"saved game");if !value.practice.fen.isEmpty,value.practice.fen != rules.fen{throw CheckmateError.invalid("Saved game checksum does not match its history.")}
        // Take Back's boundary lies within its game, or Take Back stays disabled until play passes it.
        guard (0...plies).contains(value.practice.startPly) else{throw CheckmateError.invalid("The saved game's practice start is beyond its moves.")}
        let previousPlies=value.practice.previousGame.isEmpty ? 0:try replay(value.practice.previousGame,"previous game")
        guard (0...previousPlies).contains(value.practice.previousStartPly) else{throw CheckmateError.invalid("The previous game's practice start is beyond its moves.")}
    }
    /// The mainline moves `ChessRules.restore` (chess.js's PGN grammar) would replay, counted from the text alone so the
    /// move bound holds before any replay. Linear in the text. Following that grammar: a move is castling written with
    /// zeros (`0-0`, `0-0-0`) or a letter followed by one or more of `[a-zA-Z1-8=-]` (so `O-O`, `e8=Q`, `Nbd7`);
    /// move numbers (`1.`, `1...`, attached as in `1.Nf3` or separate), results (`1-0`, `0-1`, `1/2-1/2`, `*`), NAGs
    /// (`$1`), suffixes (`!?`, `+`, `#`), tag pairs, brace and rest-of-line comments carry no move; moves inside `( )`
    /// variations are alternatives, not the mainline. Text the grammar rejects fails in `restore` whatever this counts.
    static func mainlineMoveCount(_ pgn:String)->Int {
        let text=Array(pgn.utf8),end=text.count;var i=0,depth=0,count=0
        func isLetter(_ c:UInt8)->Bool {(c>=0x41 && c<=0x5A) || (c>=0x61 && c<=0x7A)}
        func isDigit(_ c:UInt8)->Bool {c>=0x30 && c<=0x39}
        func continuesMove(_ c:UInt8)->Bool {isLetter(c) || (c>=0x31 && c<=0x38) || c==UInt8(ascii:"-") || c==UInt8(ascii:"=")}
        func startsWith(_ literal:StaticString)->Bool {let length=literal.utf8CodeUnitCount;guard i+length<=end else{return false};return (0..<length).allSatisfy{text[i+$0]==literal.utf8Start[$0]}}
        func skip(past terminator:UInt8){while i<end,text[i] != terminator{i+=1};i+=1}
        while i<end {
            let c=text[i]
            switch c {
            case UInt8(ascii:"{"):skip(past:UInt8(ascii:"}"))
            case UInt8(ascii:";"):while i<end,text[i] != UInt8(ascii:"\n"),text[i] != UInt8(ascii:"\r"){i+=1}
            // A tag pair: `[`, name, quoted value (which may hold any character but a quote), `]`.
            case UInt8(ascii:"["):skip(past:UInt8(ascii:"\""));skip(past:UInt8(ascii:"\""));skip(past:UInt8(ascii:"]"))
            case UInt8(ascii:"("):depth+=1;i+=1
            case UInt8(ascii:")"):depth=max(0,depth-1);i+=1
            case UInt8(ascii:"$"):i+=1;while i<end,isDigit(text[i]){i+=1}
            case UInt8(ascii:"0") where startsWith("0-0"):i+=3;if startsWith("-0"){i+=2};if depth==0{count+=1}
            // A move number ends in dots, which the scan passes over; digits joined by `-` or `/` are a result.
            case _ where isDigit(c):while i<end,isDigit(text[i]){i+=1};if i<end,text[i]==UInt8(ascii:"-") || text[i]==UInt8(ascii:"/"){while i<end,isDigit(text[i]) || text[i]==UInt8(ascii:"-") || text[i]==UInt8(ascii:"/"){i+=1}}
            case _ where isLetter(c):i+=1;let body=i;while i<end,continuesMove(text[i]){i+=1};if i>body,depth==0{count+=1}
            default:i+=1
            }
        }
        return count
    }
    public func save(_ state:ApplicationState) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let data=try Self.encoded(state,tooLarge:"Saved state is too large.")  // load() refuses larger files
        try requireFirstLaunchBackup()
        if FileManager.default.fileExists(atPath:url.path) {try Self.copy(url,to:backupURL)}
        try Self.write(data,to:url)
        guard try Data(contentsOf:url)==data else{throw CheckmateError.unavailable("Saved state read-back failed.")}
    }
    public func preserveBeforeImport(_ state:ApplicationState)throws -> URL {try Self.validate(state);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);let archive=directory.appendingPathComponent("state-before-import-"+UUID().uuidString+".json");try Self.write(Self.bounded(state,tooLarge:"The current progress is too large to keep before importing."),to:archive);pruneImportBackups();return archive}
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
    /// Whether this version's first-launch backup is still unwritten (not yet attempted, or failed): until it is written,
    /// the first save or restore attempts it and replaces nothing if it fails, so even a launch that never called
    /// `preserveFirstLaunchBackup` (a recovery from an unreadable state) keeps the state this version found.
    private var firstLaunchBackupPending=true
    public func preserveFirstLaunchBackup(){
        do{try writeFirstLaunchBackup();firstLaunchBackupPending=false}catch{firstLaunchBackupPending=true;NativeLog.storage.error("First-launch backup could not be written")}
    }
    /// No state file is nothing to preserve; a state file that cannot be copied is a failure.
    private func writeFirstLaunchBackup()throws {guard !FileManager.default.fileExists(atPath:firstLaunchBackupURL.path),FileManager.default.fileExists(atPath:url.path) else{return};try Self.copy(url,to:firstLaunchBackupURL)}
    private func requireFirstLaunchBackup()throws {
        guard firstLaunchBackupPending else{return}
        do{try writeFirstLaunchBackup();firstLaunchBackupPending=false}catch{throw CheckmateError.unavailable("Your saved progress could not be backed up for this version of Checkmate, so it was not replaced.")}
    }
    public func restoreBackup()throws {
        let data=try Self.read(backupURL,tooLarge:"Backup too large");let value=try JSONDecoder().decode(ApplicationState.self,from:data);try Self.validate(value)
        try requireFirstLaunchBackup()
        if FileManager.default.fileExists(atPath:url.path){try Self.copy(url,to:directory.appendingPathComponent("state-preserved-"+UUID().uuidString+".json"))}
        try Self.write(data,to:url)
    }
    /// Copies the saved file as it is, whatever its size or content: recovery exports a file the app cannot read.
    public func export(to destination:URL) throws {try Self.copy(url,to:destination)}
    /// Writes `state` itself rather than the last saved file, so an export still works when saving does not.
    public func exportState(_ state:ApplicationState,to destination:URL) throws {
        try Self.encoded(state,tooLarge:"The progress is too large to export.").write(to:destination,options:.atomic)  // import refuses larger archives
    }
    /// The validated, timestamped bytes of `state` as saved and exported, proven to decode and within the size limit.
    private static func encoded(_ state:ApplicationState,tooLarge:String)throws -> Data {
        try validate(state);var value=state;value.savedAt=Date();return try bounded(value,tooLarge:tooLarge)
    }
    /// The bytes of `state` as written, proven to decode and within the size limit every reader enforces.
    private static func bounded(_ state:ApplicationState,tooLarge:String)throws -> Data {
        let data=try serialized(state);_ = try JSONDecoder().decode(ApplicationState.self,from:data)
        guard data.count<=maximumBytes else{throw CheckmateError.invalid(tooLarge)};return data
    }
    /// Writes `data` atomically, readable by the owner only.
    private static func write(_ data:Data,to destination:URL)throws {try data.write(to:destination,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)}
    /// Copies a state file through the file system, never loading it, then moves it into place in one step, readable by
    /// the owner only. Only a regular file is copied.
    private static func copy(_ source:URL,to destination:URL)throws {
        guard try source.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true else{throw CheckmateError.unavailable("The saved file is not a regular file.")}
        let files=FileManager.default,staging=try files.url(for:.itemReplacementDirectory,in:.userDomainMask,appropriateFor:destination.deletingLastPathComponent(),create:true);defer{try? files.removeItem(at:staging)}
        let temporary=staging.appendingPathComponent(destination.lastPathComponent);try files.copyItem(at:source,to:temporary);try files.setAttributes([.posixPermissions:0o600],ofItemAtPath:temporary.path)
        if files.fileExists(atPath:destination.path){_ = try files.replaceItemAt(destination,withItemAt:temporary)}else{try files.moveItem(at:temporary,to:destination)}
    }
    /// A state file's bytes, reading at most one byte past the limit so an oversized or corrupt file is refused
    /// without being loaded whole.
    private static func read(_ url:URL,tooLarge:String)throws -> Data {
        let handle=try FileHandle(forReadingFrom:url);defer{try? handle.close()}
        var data=Data();while data.count<=maximumBytes,let chunk=try handle.read(upToCount:maximumBytes+1-data.count),!chunk.isEmpty{data.append(chunk)};guard data.count<=maximumBytes else{throw CheckmateError.invalid(tooLarge)};return data
    }
    /// The state's JSON with the fields a newer build wrote (`unknownFields`) kept.
    private static func serialized(_ state:ApplicationState)throws -> Data {
        guard let written=try JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as? [String:Any] else{throw CheckmateError.invalid("The state did not encode as an object.")}
        return try JSONSerialization.data(withJSONObject:ApplicationState.merged(written,state.unknownFields,nested:state.unknownNestedFields),options:[.sortedKeys,.prettyPrinted])
    }
    /// Start fresh after a launch failure: the unreadable file is kept beside the new state, never deleted.
    @discardableResult public func setAsideUnreadableState() throws -> URL {
        let kept=directory.appendingPathComponent("state-unreadable-"+UUID().uuidString+".json")
        try FileManager.default.moveItem(at:url,to:kept);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:kept.path);return kept
    }
}
