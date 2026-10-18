import Foundation

/// Which opponent levels each simplified mini-game offers, and so which level a new run freezes (plan D4, D8).
/// The picker shows exactly `levels(for:)`; a game with one level or none shows no picker and plays `fallbackLevel`.
public enum MiniGameOffering {
    /// The level a game plays when it offers no choice, or the learner's preference is not offered: today's default.
    public static let fallbackLevel="standard"
    /// The levels each game offers, weakest first: calibration's verdicts (WI-016,
    /// `Content/calibration/mini-game-results.json`), which a unit test keeps equal to this table. A level that did not
    /// separate from Steady against the greedy reference, or a Gentle that is not accessible, is withdrawn; the fallback
    /// level is always offered. A run already frozen at a withdrawn level finishes at it, labelled. Knight Corners has
    /// no opponent.
    static let calibrated:[MiniGameKind:[String]]=[
        .pawnDuel:["beginner","standard"],.rookSweep:["beginner","standard"],.rooksAndPawns:["beginner","standard"],.bishopSweep:["beginner","standard"],
        .bishopsAndPawns:["beginner","standard"],.queenVsPawns:["beginner","standard"],.knightCapture:["beginner","standard"],
    ]
    /// Replaces the calibrated table in tests of the level mechanism, which need levels calibration may withdraw.
    static var testTable:[MiniGameKind:[String]]?
    static var table:[MiniGameKind:[String]] {testTable ?? calibrated}
    public static func levels(for kind:MiniGameKind)->[String] {kind.solo ? []:table[kind] ?? []}
    /// Whether the game shows a level picker: only when there is a choice to make.
    public static func offersChoice(_ kind:MiniGameKind)->Bool {levels(for:kind).count>1}
    /// The level a new run of `kind` freezes: the learner's preference for this game, else the global preference,
    /// whichever is offered first; else `fallbackLevel`. `offered` replaces the table (tests).
    public static func level(for kind:MiniGameKind,settings:AppSettings,offered:[String]?=nil)->String {
        let allowed=offered ?? levels(for:kind)
        return [settings.miniOpponentProfiles[kind.rawValue],settings.miniOpponentProfile].compactMap{$0}.first{allowed.contains($0)} ?? fallbackLevel
    }
    /// The name a level is shown by (plan D4); the stored profile names stay as they are.
    public static func title(_ level:String)->String {["beginner":"Gentle","standard":"Steady","challenging":"Strong"][level] ?? level.capitalized}
}
