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
    public static func title(_ level:String)->String {["beginner":"Gentle","standard":"Steady","challenging":"Strong","legacy":"Legacy strength"][level] ?? TrainingOpponentLevel(rawValue:level)?.title ?? level.capitalized}
    // MARK: Standard-rule training games
    /// The level a standard-rule game plays when it offers no choice: today's coded strength (plan D4), Steady for a
    /// guided game (`.skill(3)`), Strong for an ending or a position game (`.skill(20)`).
    public static func fallbackLevel(for check:TrainingCheck?)->TrainingOpponentLevel {check == .guidedGame ? .steady:.strong}
    /// The levels a standard-rule game offers, weakest first. Calibration (WI-016) has published nothing for them yet,
    /// so with position games off each plays its fallback and shows no picker: nothing visible changes. Their preview
    /// (`CHECKMATE_POSITION_GAMES`) offers all three, uncalibrated, for development and calibration only, except the
    /// stalemate trap (`finish-the-game` kqk): it offers only Strong, because a weaker defender rarely heads for the
    /// stalemate the drill is about.
    public static func levels(entry:String,variant:String,check:TrainingCheck?)->[TrainingOpponentLevel] {
        guard TrainingRolloutPolicy.positionGamesEnabled,!(entry=="finish-the-game" && variant=="kqk") else{return [fallbackLevel(for:check)]}
        return TrainingOpponentLevel.allCases
    }
    /// The level a new attempt freezes: the learner's preference for this entry when offered, else the fallback.
    /// `offered` replaces the table (tests).
    public static func level(entry:String,variant:String,check:TrainingCheck?,settings:AppSettings,offered:[TrainingOpponentLevel]?=nil)->TrainingOpponentLevel {
        let allowed=offered ?? levels(entry:entry,variant:variant,check:check)
        return settings.positionGameLevels?[entry].flatMap(TrainingOpponentLevel.init(rawValue:)).flatMap{allowed.contains($0) ? $0:nil} ?? (allowed.contains(fallbackLevel(for:check)) ? fallbackLevel(for:check):allowed.first ?? fallbackLevel(for:check))
    }
}
