import Foundation

/// Which opponent levels each simplified mini-game offers, and so which level a new run freezes (plan D4, D8).
/// The picker shows exactly `levels(for:)`; a game with one level or none shows no picker and plays `fallbackLevel`.
public enum MiniGameOffering {
    /// The level a game plays when it offers no choice, or the learner's preference is not offered: today's default.
    public static let fallbackLevel="standard"
    private static let today=MiniOpponentPolicy.profiles
    /// The levels each game offers, weakest first. Until calibration (WI-016) publishes which levels separate for which
    /// game, every competitive game keeps today's three, so nothing visible changes; WI-016 replaces this table with
    /// its results. A game missing here offers no choice. Knight Corners has no opponent.
    static let table:[MiniGameKind:[String]]=[
        .pawnDuel:today,.rookSweep:today,.rooksAndPawns:today,.bishopSweep:today,.bishopsAndPawns:today,.queenVsPawns:today,.knightCapture:today,
    ]
    public static func levels(for kind:MiniGameKind)->[String] {kind.solo ? []:table[kind] ?? []}
    /// Whether the game shows a level picker: only when there is a choice to make.
    public static func offersChoice(_ kind:MiniGameKind)->Bool {levels(for:kind).count>1}
    /// The level a new run of `kind` freezes: the learner's preference for this game, else the global preference,
    /// whichever is offered first; else `fallbackLevel`. `offered` replaces the table (tests).
    public static func level(for kind:MiniGameKind,settings:AppSettings,offered:[String]?=nil)->String {
        let allowed=offered ?? levels(for:kind)
        return [settings.miniOpponentProfiles[kind.rawValue],settings.miniOpponentProfile].compactMap{$0}.first{allowed.contains($0)} ?? fallbackLevel
    }
    /// The name a level is shown by.
    public static func title(_ level:String)->String {["beginner":"Beginner","standard":"Standard","challenging":"Challenging"][level] ?? level.capitalized}
}
