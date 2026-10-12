import Foundation

/// Carries progress saved by the first course edition into the current one. The course was rewritten with new
/// lesson and mini-game identifiers, so stored identifiers are looked up by digest: the repository never spells a
/// retired identifier, yet a learner's completed lessons, current lesson and mini-game records follow their rename.
/// Identifiers not in a table are kept as they are. Applying a migration twice changes nothing.
public enum ProgressMigration {
    /// The course edition this build writes. Progress without an edition was saved by edition 1.
    public static let courseEdition=2
    /// The table key of an identifier: 64-bit FNV-1a of "checkmate-id-v1|" + identifier, as 16 hex digits. A stable
    /// lookup key, not a secret; plain Swift keeps the domain free of platform frameworks.
    public static func digest(_ id:String)->String {
        var hash:UInt64=0xcbf29ce484222325
        for byte in ("checkmate-id-v1|"+id).utf8 {hash=(hash ^ UInt64(byte)) &* 0x100000001b3}
        let hex=String(hash,radix:16);return String(repeating:"0",count:16-hex.count)+hex
    }
    /// Edition 1 lesson identifiers that changed, by digest. Two edition 1 lessons became "castling".
    public static let lessons:[String:String]=[
        "20e7cc934da126a8":"board","e470a6ffde1a4a2c":"pawn-duel","51f4998da74c3194":"rook-practice",
        "3ae84a095fd12eac":"bishop-practice","cc1fd73a40222bad":"queen-practice","b8a7a2259d3d4354":"knight-practice",
        "597d340ade4b93ae":"safe-squares","132e744b4a06dac9":"check-and-checkmate","5a192fda863ff6ea":"castling",
        "007655bab484db7b":"castling","75aa014660a889c5":"castling-rules","618f066e82c1453e":"promotion-en-passant",
        "5a68228a2a5e7ea1":"piece-values","3ff0813a562c4a09":"rules-review","66a6a5fedcceeec1":"draws",
        "3a08aeb036df22d7":"notation","21245443dd04075e":"opening","e139d0c7c8593f78":"counting-material",
        "a288dc531b9b4f6c":"scholars-mate","6c0193b86365bb9c":"two-rook-mate","50d851ff5058906d":"queen-mate",
        "bd2fb596b7609998":"rook-mate","88e8c41c3d183b70":"puzzles-material","baee8940ce2abed8":"puzzles-mate",
        "291dad3077ab37d9":"famous-game",
    ]
    /// Edition 1 mini-game identifiers that changed, by digest. They are also the training entries' identifiers.
    public static let miniGames:[String:String]=[
        "e470a6ffde1a4a2c":"pawn-duel","9569fbb2040913a3":"rook-sweep","eff55d7d3afc921b":"bishop-sweep",
        "9d48570fa5cda553":"queen-vs-pawns","70a0e80853573d2f":"knight-capture","8bd4428cab3ac315":"knight-corners",
    ]
    public static func renamed(_ id:String,in table:[String:String])->String {table[digest(id)] ?? id}

    /// A saved state (its top-level JSON object) in edition 2 terms, before anything is decoded, so neither the typed
    /// fields nor the unknown fields kept for newer builds still hold an edition 1 identifier.
    ///
    /// Every lesson's narration and every puzzle was replaced, so a reading position, an answered exercise or a puzzle
    /// record refers to content that no longer exists: those restart. Completed lessons and the current lesson carry
    /// over under their new identifiers. A mini-game's layout and goals changed, so a saved one restarts in its renamed
    /// game, keeping only whether the learner played the computer.
    public static func migrate(state raw:[String:JSONValue],lessons lessonTable:[String:String]=lessons,games gameTable:[String:String]=miniGames)->[String:JSONValue] {
        var state=raw
        if case .object(var course)?=state["course"],edition(course["edition"])<courseEdition {
            if case .string(let id)?=course["lessonID"]{course["lessonID"] = .string(renamed(id,in:lessonTable))}
            if case .array(let done)?=course["completed"] {
                var seen=Set<String>()
                course["completed"] = .array(done.map{if case .string(let id)=$0{return .string(renamed(id,in:lessonTable))};return $0}.filter{if case .string(let id)=$0{return seen.insert(id).inserted};return true})
            }
            course["step"] = .integer(0);course["segmentID"]=nil;course["positions"]=nil;course["answered"] = .array([]);course["edition"] = .integer(Int64(courseEdition))
            state["course"] = .object(course);state["puzzles"] = .object([:])
        }
        if case .object(let games)?=state["miniGames"] {
            var out:[String:JSONValue]=[:]
            for (key,game) in games where MiniGameKind(rawValue:key) != nil || gameTable[digest(key)]==nil {out[key]=game}
            for (key,game) in games {
                guard let id=gameTable[digest(key)],out[id]==nil,let kind=MiniGameKind(rawValue:id) else{continue}
                var computer=true;if case .object(let object)=game,case .bool(let value)?=object["computer"]{computer=value}
                if let fresh=try? JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(MiniGameState(kind:kind,computer:computer))){out[id]=fresh}
            }
            state["miniGames"] = .object(out)
        }
        if let training=state["training"]{state["training"]=migrate(training:training,games:gameTable)}
        return state
    }
    private static func edition(_ value:JSONValue?)->Int {
        switch value {case .integer(let v)?:return Int(clamping:v);case .unsigned(let v)?:return Int(clamping:v);case .number(let v)?:return Int(exactly:v.rounded(.down)) ?? 1;default:return 1}
    }
    /// A saved training record with edition 1 mini-game identifiers renamed wherever the record names a game:
    /// per-entry summaries, credited runs, completion events, attempts, the retry queue and the active attempt.
    public static func migrate(training:JSONValue,games table:[String:String]=miniGames)->JSONValue {
        guard case .object(var object)=training else{return training}
        func rename(_ value:JSONValue)->JSONValue {if case .string(let id)=value{return .string(renamed(id,in:table))};return value}
        func renameKeys(_ value:JSONValue?)->JSONValue? {
            guard case .object(let map)?=value else{return value}
            var out:[String:JSONValue]=[:];for (key,entry) in map{out[renamed(key,in:table)]=entry};return .object(out)
        }
        func renameField(_ field:String,in value:JSONValue)->JSONValue {
            guard case .object(var record)=value,let id=record[field] else{return value};record[field]=rename(id);return .object(record)
        }
        func renameEach(_ list:String,_ field:String) {if case .array(let items)?=object[list]{object[list] = .array(items.map{renameField(field,in:$0)})}}
        object["summaries"]=renameKeys(object["summaries"]);object["creditedRuns"]=renameKeys(object["creditedRuns"])
        renameEach("events","kind");renameEach("attempts","entry");renameEach("retryQueue","entry")
        if let active=object["active"]{object["active"]=renameField("entry",in:active)}
        return .object(object)
    }
}
