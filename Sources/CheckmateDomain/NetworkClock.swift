import Foundation
/// The host's authoritative clocks (D6). Only the host has one; receivers display `NetworkClocks` counting down.
///
/// Every event settles first: `remaining[active] -= now - settledAt; settledAt = now`. Settling is invisible in effect
/// (the time left at any instant is the same however often it settles), which is why a refused command may settle
/// too: start at 10 s, refused at t=2 (8 s left), accepted at t=3, 7 s before the increment, never charged twice.
public struct NetworkClock:Equatable {
    public let timeControl:NetworkTimeControl
    public private(set) var white:Duration,black:Duration
    /// The side whose clock runs, or nil while paused, before the first move, or after the end.
    public private(set) var active:NetworkSide?
    public private(set) var settledAt:NetworkInstant
    /// False until the first move is applied (White's, in a game from the start). It survives disconnects, so a
    /// resume at zero plies starts no clock (R4-1).
    public private(set) var clockStarted=false
    /// Nil for an untimed game, which has no clocks at all.
    public init?(timeControl:NetworkTimeControl,at now:NetworkInstant){guard let initial=timeControl.initial else{return nil};self.timeControl=timeControl;white=initial;black=initial;settledAt=now}
    public func remaining(_ side:NetworkSide)->Duration {side == .white ? white:black}
    private mutating func set(_ side:NetworkSide,_ value:Duration){if side == .white {white=value}else{black=value}}
    /// Instants come from one monotonic clock in queue order, so `now` is never earlier; if it ever were, nothing is
    /// charged rather than time being given back.
    public mutating func settle(at now:NetworkInstant){
        guard now>=settledAt else{return}
        if let side=active {set(side,remaining(side)-(now-settledAt))}
        settledAt=now
    }
    /// The side whose time has run out, once settled.
    public var flagged:NetworkSide? {active.flatMap{remaining($0) <= .zero ? $0:nil}}
    /// An accepted move, already settled at its instant: the mover gains the increment for a move its own clock timed
    /// (so the opening move, made before any clock ran, gains none), then the opponent's clock runs from `settledAt`.
    public mutating func moveApplied(by mover:NetworkSide){
        if clockStarted {set(mover,remaining(mover)+timeControl.increment)}else{clockStarted=true}
        active=mover.opponent
    }
    /// The guest dropped, or the game ended: settle, then stop.
    public mutating func pause(at now:NetworkInstant){settle(at:now);active=nil}
    /// The guest is back: the side to move runs again only if a clock had started, from now.
    public mutating func resume(sideToMove:NetworkSide,at now:NetworkInstant){active=clockStarted ? sideToMove:nil;settledAt=max(settledAt,now)}
    /// When the running clock reaches zero: the flag-fall timer, rescheduled after every event.
    public var flagDeadline:NetworkInstant? {active.map{settledAt+remaining($0)}}
    /// Both clocks as they read at `now`, without settling: what a message or a snapshot carries.
    public func clocks(at now:NetworkInstant)->NetworkClocks {
        func reading(_ side:NetworkSide)->Int {let left=side==active && now>settledAt ? remaining(side)-(now-settledAt):remaining(side);return max(0,left.networkMilliseconds)}
        return NetworkClocks(white:reading(.white),black:reading(.black),active:active)
    }
    /// The outcome of a flag fall (D6). The side with time left wins, unless it has only its king, which can never
    /// checkmate: then it is a draw. No other material test exists, because chess.js documents mates such as bishop
    /// against bishop with blockers; positions where nothing can mate are already drawn automatically before any flag.
    public static func flagOutcome(flagged:NetworkSide,opponentHasOnlyKing:Bool)->NetworkOutcome {
        NetworkOutcome(result:opponentHasOnlyKing ? .draw:.win(for:flagged.opponent),termination:.time)
    }
}
