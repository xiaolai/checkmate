import AppKit
/// The review's Go commands (R-8, after Lichess), shared by the board's keys and the Go menu: ←/→ along the line shown,
/// an imagined one included; ↑/↓ between the alternatives played from the same position; Home/End to the line's ends.
enum ReviewGo:Int,CaseIterable {
    case previousMove,nextMove,previousVariation,nextVariation,firstMove,lastMove,playPause
    /// The board's key for a command. Space plays the original game; in an imagined line it is left to the board, which
    /// uses it to choose the focused square.
    init?(key:UInt16,imagined:Bool){
        switch key {
        case 123:self = .previousMove
        case 124:self = .nextMove
        case 126:self = .previousVariation
        case 125:self = .nextVariation
        case 115:self = .firstMove
        case 119:self = .lastMove
        case 49 where !imagined:self = .playPause
        default:return nil
        }
    }
    /// The Go menu's key equivalent, shown without modifiers; Space stays with the board and the bar's ⌥⌘P.
    var menuKey:String? {
        let key:Int
        switch self {
        case .previousMove:key=NSLeftArrowFunctionKey
        case .nextMove:key=NSRightArrowFunctionKey
        case .previousVariation:key=NSUpArrowFunctionKey
        case .nextVariation:key=NSDownArrowFunctionKey
        case .firstMove:key=NSHomeFunctionKey
        case .lastMove:key=NSEndFunctionKey
        case .playPause:return nil
        }
        return UnicodeScalar(key).map{String(Character($0))}
    }
}
