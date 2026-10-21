import SwiftUI
import CheckmateCore

extension ControlBarModel {
    /// The network game's bar (B-1): whose turn it is and both clocks in the centre, then Accept or Decline an open
    /// draw offer, Offer Draw, Resign and Flip Board, so the game needs no drawer open. The lobby has no bar.
    @MainActor static func networkBar(_ game:NetworkGameController)->ControlBarModel {
        guard game.part != nil,let text=game.statusText else{return ControlBarModel()}
        var bar=ControlBarModel(statusInCentre:true)
        let running=game.outcome==nil && game.link == .live && game.hostPhase != .reserved && game.hostPhase != .waiting
        bar.status = running ? .turn(side:game.rules.turn,label:text):.text(text)
        bar.clocks=game.timeControl != .untimed
        if game.canAnswerDraw{bar.trailing+=[ControlBarItem(action:.acceptDraw,label:String(localized:"Accept Draw",bundle:.checkmate),prominent:true),ControlBarItem(action:.declineDraw,label:String(localized:"Decline",bundle:.checkmate))]}
        if game.learnerSide != nil{bar.trailing+=[ControlBarItem(action:.offerDraw,label:String(localized:"Offer Draw",bundle:.checkmate),enabled:game.canOfferDraw),ControlBarItem(action:.resign,label:String(localized:"Resign…",bundle:.checkmate),enabled:game.canResign)]}
        bar.trailing.append(ControlBarItem(action:.flipBoard,symbol:.flipBoard,label:String(localized:"Flip Board",bundle:.checkmate),enabled:game.seat != nil))
        return bar
    }
}

/// Both network clocks in the bar, in the board's order, ticking in tenths under ten seconds and red under twenty
/// (B-2). The learner's own clock passing twenty seconds sounds the low-time warning once per game.
struct NetworkBarClocks:View {
    @ObservedObject var game:NetworkGameController
    let warning:NetworkLowTimeWarning
    var body:some View {
        TimelineView(.periodic(from:.now,by:0.1)){_ in
            let clocks=game.currentClocks,top:NetworkSide=game.blackAtBottom ? .white:.black
            HStack(spacing:Metrics.smallGap){face(top.opponent,clocks);face(top,clocks)}
                .onChange(of:clocks,initial:true){_,now in warning.check(now,learner:game.learnerSide,game:game.record?.gameID.text)}
        }
    }
    @ViewBuilder private func face(_ side:NetworkSide,_ clocks:NetworkClocks?)->some View {
        if let clocks {
            let left=clocks.remaining(side),colour=side == .white ? "white":"black"
            HStack(spacing:4){
                TurnIndicator(side:side.rawValue,label:side == .white ? String(localized:"White",bundle:.checkmate):String(localized:"Black",bundle:.checkmate))
                Text(NetworkDetail.clock(left)).font(.system(.callout,design:.monospaced)).fontWeight(clocks.active==side ? .semibold:.regular)
                    .foregroundStyle(NetworkDetail.low(left) ? Color(nsColor:NativeColors.error):clocks.active==side ? .primary:.secondary)
            }
            .accessibilityElement(children:.ignore).accessibilityLabel(String(localized:"network.bar.playerClock",defaultValue:"\(game.players.name(side)), \(NetworkDetail.spokenClock(left))",bundle:.checkmate,comment:"A player's clock: the player, then the time left")).accessibilityIdentifier("bar-\(colour)-clock")
        }
    }
}

/// The low-time warning: once per game, when the learner's own running clock is under twenty seconds. A spectator
/// has no clock of their own, and a clock not running is not a warning.
@MainActor final class NetworkLowTimeWarning {
    private let sound:()->Void
    private var warned:Set<String>=[]
    init(sound:@escaping ()->Void){self.sound=sound}
    func check(_ clocks:NetworkClocks?,learner:NetworkSide?,game:String?){
        guard let clocks,let learner,let game,clocks.active==learner,NetworkDetail.low(clocks.remaining(learner)),warned.insert(game).inserted else{return}
        sound()
    }
}
