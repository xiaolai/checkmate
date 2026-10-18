import CheckmateDomain
import Foundation
/// What a finished or interrupted network game leaves behind (LAN-play plan D9): the record handed to Review, and the
/// crash file that lets the next launch say the game ended when Checkmate closed.
public enum NetworkGameRecord {
    /// The review record: the D9 headers (Event, White, Black, Date, Result, TimeControl, Termination from `ended`, and
    /// Assistance when either side had any) over the game's moves, each assisted move followed by `{Hint shown}`
    /// (assistance plan A11). An interrupted game has the result `*`.
    ///
    /// `moves` is the game's SAN as this Mac's own rules replayed the record, never the record's text: a peer's PGN may
    /// carry tags, comments or characters that a text scan would read as moves (a tag value spanning lines, a mark that
    /// joins a comment's closing brace). A declared start (mini-games plan D7) is written as SetUp/FEN, and the moves
    /// are numbered from it.
    public static func reviewPGN(_ game:NetworkPublicGame,moves:[String],on date:Date,calendar:Calendar=Calendar(identifier:.gregorian))->String {
        let day=calendar.dateComponents([.year,.month,.day],from:date)
        let stamp=String(format:"%04d.%02d.%02d",day.year ?? 0,day.month ?? 0,day.day ?? 0)
        let headers=game.recordHeaders(date:stamp).map{"[\($0.name) \"\(escaped($0.value))\"]"}.joined(separator:"\n")
        return headers+"\n\n"+movetext(moves,result:game.outcome?.result.rawValue ?? "*",assisted:Set(game.assistedPlies),start:game.start)
    }
    /// The comment after each assisted move (A11). Self-reported by the mover, as the game's wording says.
    static let assistedComment="{Hint shown}"
    /// Numbered movetext from the start's first move, ending in `result`: "37... Kd7 38. Ke5" when Black moves first at
    /// move 37. The plies in `assisted` (counted from 1) are followed by `assistedComment`.
    static func movetext(_ moves:[String],result:String,assisted:Set<Int>=[],start:String=NetworkStart.standard)->String {
        var tokens:[String]=[]
        // Plies counted from White's move of the start's first full move: Black first is ply 1 of that count.
        let offset=NetworkStart.side(start) == .black ? 1:0,first=NetworkStart.fullmove(start)
        for (index,san) in moves.enumerated() {
            let ply=index+offset
            if ply%2==0 {tokens.append("\(first+ply/2).")}else if index==0 {tokens.append("\(first)...")}
            tokens.append(san);if assisted.contains(index+1){tokens.append(assistedComment)}
        }
        return (tokens+[result]).joined(separator:" ")
    }
    private static func escaped(_ value:String)->String {value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")}
}

/// `NetworkGames/current.json` in the data directory (D9): the last public record of the game in progress, and the
/// learner's part in it. It holds no credential or claim, because `NetworkPublicGame` has no field for one. Written
/// while a game runs, deleted on a clean exit and after the next launch's notice.
public struct NetworkCrashFile {
    /// The learner's part, so the notice can name the other player.
    public enum Part:String,Codable {case white,black,spectator}
    public struct Entry:Codable,Equatable {
        public let game:NetworkPublicGame
        public let part:Part
        public init(game:NetworkPublicGame,part:Part){self.game=game;self.part=part}
        /// "Your network game with Ben ended when Checkmate closed."
        public var notice:String {
            switch part {
            case .white:return "Your network game with \(game.blackName ?? "your opponent") ended when Checkmate closed."
            case .black:return "Your network game with \(game.whiteName ?? "your opponent") ended when Checkmate closed."
            case .spectator:return "The network game you were watching ended when Checkmate closed."
            }
        }
    }
    public let url:URL
    public init(dataDirectory:URL){url=dataDirectory.appendingPathComponent("NetworkGames",isDirectory:true).appendingPathComponent("current.json")}
    public func save(_ entry:Entry)throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        try encoder.encode(entry).write(to:url,options:[.atomic])
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    /// The entry a previous run left, if any. An unreadable file is removed, so it can't nag on every launch.
    public func pending()->Entry? {
        guard let data=try? Data(contentsOf:url) else{return nil}
        guard let entry=try? JSONDecoder().decode(Entry.self,from:data) else{clear();return nil}
        return entry
    }
    public func clear(){try? FileManager.default.removeItem(at:url)}
}
