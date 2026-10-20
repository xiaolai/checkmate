import Foundation
/// A network game played by a simplified mini-game's rules (mini-games plan D7, L2, `docs/network-protocol-1.3.md`),
/// named by its descriptor `mini:<kind>@<rulesVersion>`. Only the competitive kinds at this build's
/// `MiniGameRules.version` are rulesets: a solo kind, an unknown kind or another rules version is none, everywhere.
/// The descriptor is part of the authoritative game: fixed when hosted, carried by every record, pinned by receivers.
public struct NetworkRuleset:Hashable,CustomStringConvertible {
    public let kind:MiniGameKind
    public static let prefix="mini:",capabilityPrefix="ruleset:"
    /// The longest descriptor any kind has (`mini:bishops-and-pawns@1`).
    public static let maximumDescriptorBytes=24
    /// Nil for a solo kind: nothing is played against anyone there.
    public init?(_ kind:MiniGameKind){guard !kind.solo else{return nil};self.kind=kind}
    /// Exactly `mini:<kind>@<MiniGameRules.version>`, decimal with no leading zero; anything else is nil.
    public init?(descriptor:String){
        guard descriptor.utf8.count<=Self.maximumDescriptorBytes,descriptor.hasPrefix(Self.prefix),let at=descriptor.lastIndex(of:"@") else{return nil}
        let name=descriptor[descriptor.index(descriptor.startIndex,offsetBy:Self.prefix.count)..<at],version=descriptor[descriptor.index(after:at)...]
        guard let kind=MiniGameKind(rawValue:String(name)),String(MiniGameRules.version)==version else{return nil}
        self.init(kind)
    }
    public var descriptor:String {Self.prefix+kind.rawValue+"@\(MiniGameRules.version)"}
    public var description:String {descriptor}
    /// What a game of this ruleset requires every guest and spectator to state (at most 32 bytes).
    public var capability:String {Self.capabilityPrefix+descriptor}
    /// Every ruleset this build plays and verifies, in `MiniGameKind` order.
    public static let supported:[NetworkRuleset]=MiniGameKind.allCases.compactMap(NetworkRuleset.init)
    /// The kind a TXT `variant` names, for the lobby's label only: any rules version, nil when unreadable.
    public static func displayKind(_ variant:String?)->MiniGameKind? {
        guard let variant,variant.utf8.count<=Self.maximumDescriptorBytes+8,variant.hasPrefix(prefix),let at=variant.lastIndex(of:"@") else{return nil}
        return MiniGameKind(rawValue:String(variant[variant.index(variant.startIndex,offsetBy:prefix.count)..<at])).flatMap{$0.solo ? nil:$0}
    }

    // MARK: Limits (`docs/network-protocol-1.3.md`, the ruleset record)
    /// The most moves a ruleset game can hold. At most 16 pieces start in any kind (at most 15 captures) and at most 16
    /// pawns of at most 6 moves each (96 pawn moves): at most 111 irreversible plies. The 80-ply rule ends every stretch
    /// without one within 80 plies, so no game reaches 111 + 112 × 80 = 9,071 plies; 10,000 adds a margin.
    public static let maximumPlies=10_000
    /// The longest record of `moves` moves: the descriptor, then a space and four characters a move.
    public static func maximumRecordBytes(moves:Int)->Int {maximumDescriptorBytes+5*moves}

    // MARK: The record
    /// "mini:pawn-duel@1 b2b4 g7g5": the descriptor, then every move from the start.
    public func record(_ moves:[MiniGameMove])->String {([descriptor]+moves.map{$0.from+$0.to}).joined(separator:" ")}
    /// The moves of a record, read strictly and within the limits before anything is played: exactly this
    /// ruleset's descriptor, then ` <square><square>` for each move, nothing else. Throws `badRecord` otherwise.
    public func moves(of record:String)throws -> [MiniGameMove] {
        let bytes=Array(record.utf8),head=Array(descriptor.utf8)
        guard bytes.count<=Self.maximumRecordBytes(moves:Self.maximumPlies),bytes.count>=head.count,Array(bytes.prefix(head.count))==head,(bytes.count-head.count)%5==0 else{throw NetworkRulesError.badRecord}
        var moves:[MiniGameMove]=[],index=head.count
        moves.reserveCapacity((bytes.count-head.count)/5)
        func square(_ at:Int)->String? {(0x61...0x68).contains(bytes[at]) && (0x31...0x38).contains(bytes[at+1]) ? String(decoding:bytes[at...at+1],as:UTF8.self):nil}
        while index<bytes.count {
            guard bytes[index]==0x20,let from=square(index+1),let to=square(index+3) else{throw NetworkRulesError.badRecord}
            moves.append(MiniGameMove(from:from,to:to));index+=5
        }
        guard moves.count<=Self.maximumPlies else{throw NetworkRulesError.badRecord}
        return moves
    }

    // MARK: Endings
    /// The referee's ending of `state` as a network outcome, or nil while the game goes on. The referee is the
    /// authority: its rule decides the termination, in its own order (`MiniGameState.victory`, then `draw`).
    public static func ending(_ state:MiniGameState)->NetworkAutomaticEnding? {
        if let victory=state.victory {
            let side:NetworkSide=victory.side=="w" ? .white:.black
            switch victory.reason {case .farRank:return .mini(winner:side,.farRank);case .allCaptured:return .mini(winner:side,.allCaptured);case .noMoves:return .mini(winner:side,.noMoves)}
        }
        switch state.draw {
        case .unreachableTargets?:return .mini(winner:nil,.unreachableTargets)
        case .repetition?:return .mini(winner:nil,.miniRepetition)
        case .noProgress?:return .mini(winner:nil,.miniNoProgress)
        case nil:return nil
        }
    }
}
