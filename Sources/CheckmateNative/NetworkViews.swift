import SwiftUI
import CheckmateCore
/// The Play on Network pane beside the board (LAN-play plan D10): the lobby — Host a Game, and one list of found games
/// for Join and Watch — then the game's own chrome: the codes to share, names and clocks, the status, draw and hold
/// controls, Leave, and Review this game. The board area keeps its square board and centred title; nothing here is a
/// toolbar item.
struct NetworkDetail:View {
    @ObservedObject var model:NativeModel
    @ObservedObject var game:NetworkGameController
    @State private var chosen:String?
    @State private var code=""
    @State private var hosting=false
    var body:some View {
        VStack(alignment:.leading,spacing:Metrics.smallGap){
            Text(game.title).font(.title2.bold()).accessibilityIdentifier("network-title")
            if game.part==nil{lobby}else{session}
            if let notice=game.notice{Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("network-notice")}
        }
        .sheet(isPresented:$hosting){NetworkHostSheet(game:game,close:{hosting=false})}
    }

    // MARK: Lobby
    @ViewBuilder private var lobby:some View {
        Text("Play a game against someone on your local network, or watch one.").fixedSize(horizontal:false,vertical:true)
        Button("Host a Game…"){hosting=true}.controlSize(.large).accessibilityIdentifier("network-host-button")
        Divider()
        Text("Games on your network").font(.headline)
        if game.localNetworkDenied {
            Text("Checkmate needs Local Network access to find games.").fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("network-access-needed")
            Button("Local Network Settings…"){model.openLocalNetworkSettings()}.accessibilityIdentifier("network-permission-settings")
        }else if game.games.isEmpty {
            Text(game.browsing ? "Looking for games…":"No games found yet.").foregroundStyle(.secondary).accessibilityIdentifier("network-no-games")
        }
        // Join and Watch share this one list (D10).
        ForEach(game.games,id:\.gameID.text){entry in
            let selected=chosen==entry.gameID.text
            Button{chosen=entry.gameID.text}label:{
                Label(entry.displayName,systemImage:selected ? "largecircle.fill.circle":"circle").frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected:[]).accessibilityIdentifier("network-game-"+entry.gameID.text)
        }
        if let entry=game.games.first(where:{$0.gameID.text==chosen}) {
            TextField("Your name",text:$game.playerName).textFieldStyle(.roundedBorder).accessibilityIdentifier("network-name-field")
            TextField("Code",text:$code).textFieldStyle(.roundedBorder).accessibilityIdentifier("network-code-field")
            HStack {
                Button("Join"){game.join(entry,code:code)}.disabled(entry.record(.seat)==nil || code.isEmpty).accessibilityIdentifier("network-join-button")
                Button("Watch"){game.join(entry,code:code,watching:true)}.disabled(entry.record(.watch)==nil || code.isEmpty).accessibilityIdentifier("network-watch-button")
            }
            Text("Join with the play code, or watch with the watch code.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
        if let message=game.lobbyMessage{Text(message).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("network-lobby-message")}
    }

    // MARK: Session
    @ViewBuilder private var session:some View {
        if game.part == .host,game.outcome==nil,game.sessionOpen,let play=game.playCode {codes(play)}
        if game.seat != nil {players}
        if let status=game.statusText{Text(status).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("network-status")}
        if game.part == .host,game.holdExpired {
            HStack {
                Button("Claim Win"){game.claimWin()}.accessibilityIdentifier("network-claim-win")
                Button("Keep Waiting"){game.keepWaiting()}.accessibilityIdentifier("network-keep-waiting")
            }
        }
        if let offer=game.openOffer,game.outcome==nil {
            if offer.by==game.learnerSide {Text("Your draw offer is open.").foregroundStyle(.secondary).accessibilityIdentifier("network-offer-open")}
            else if game.learnerSide != nil {
                Text("\(game.players.name(offer.by)) offers a draw.").accessibilityIdentifier("network-offer-received")
                HStack {
                    Button("Accept Draw"){game.answerDraw(accept:true)}.disabled(!game.canAnswerDraw).accessibilityIdentifier("network-accept-draw")
                    Button("Decline"){game.answerDraw(accept:false)}.disabled(!game.canAnswerDraw).accessibilityIdentifier("network-decline-draw")
                }
            }else{Text("\(game.players.name(offer.by)) offered a draw.").foregroundStyle(.secondary).accessibilityIdentifier("network-offer-received")}
        }
        if game.learnerSide != nil,game.outcome==nil,game.sessionOpen,game.hostPhase != .waiting {
            HStack {
                Button("Offer Draw"){game.offerDraw()}.disabled(!game.canOfferDraw).accessibilityIdentifier("network-offer-draw")
                Button("Claim Draw"){game.claimDraw()}.disabled(!game.canClaimDraw).accessibilityIdentifier("network-claim-draw")
                Button("Resign…"){model.resignNetworkGame()}.disabled(!game.canResign).accessibilityIdentifier("network-resign")
            }
        }
        if !game.spectators.isEmpty {
            Text(game.spectators.count==1 ? "\(game.spectators[0]) is watching.":"\(game.spectators.count) people are watching.").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("network-spectators")
        }
        Divider()
        if game.canTryAgain{
            Button("Try Again"){game.tryAgain()}.controlSize(.large).accessibilityIdentifier("network-try-again")
            Text(NetworkWording.seatHeld).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("network-seat-held")
        }
        if game.canReview{Button("Review this game"){model.reviewNetworkGame()}.controlSize(.large).accessibilityIdentifier("network-review")}
        if game.sessionOpen && game.outcome==nil {
            Button(leaveTitle){model.leaveNetworkGame()}.accessibilityIdentifier("network-leave")
        }else{
            Button("Back to Games"){game.leave()}.accessibilityIdentifier("network-back-to-games")
        }
    }
    private var leaveTitle:String {
        if game.link == .connecting || game.link == .denied {return "Cancel"}
        if game.part == .spectator {return "Stop Watching"}
        if game.hostPhase == .waiting {return "Stop Hosting"}
        return game.leavingResigns ? "Leave Game…":"Leave Game"
    }
    /// The codes the host shares, grouped for reading, and read out symbol by symbol.
    private func codes(_ play:NetworkCode)->some View {
        VStack(alignment:.leading,spacing:4){
            Text("Play code").font(.caption).foregroundStyle(.secondary)
            Text(play.grouped).font(.system(.title2,design:.monospaced).bold()).textSelection(.enabled).accessibilityLabel("Play code, "+Self.spelled(play)).accessibilityIdentifier("network-play-code")
            if let watch=game.watchCode {
                Text("Watch code").font(.caption).foregroundStyle(.secondary)
                Text(watch.grouped).font(.system(.title3,design:.monospaced)).textSelection(.enabled).accessibilityLabel("Watch code, "+Self.spelled(watch)).accessibilityIdentifier("network-watch-code")
            }
            Text(game.hostPhase == .waiting ? (game.watchCode==nil ? "Give the play code to the person you're playing.":"Give the play code to the person you're playing, and the watch code to anyone watching."):game.watchCode==nil ? "":"Anyone who wants to watch needs the watch code.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
    }
    static func spelled(_ code:NetworkCode)->String {code.grouped.split(separator:"-").map{$0.map(String.init).joined(separator:" ")}.joined(separator:", ")}
    /// Names and clocks, in the board's order: the side at the top of the board first.
    @ViewBuilder private var players:some View {
        let top:NetworkSide=game.blackAtBottom ? .white:.black
        if game.timeControl == .untimed {
            VStack(alignment:.leading,spacing:6){row(top,clocks:nil);row(top.opponent,clocks:nil)}
        }else{
            TimelineView(.periodic(from:.now,by:0.25)){_ in
                let clocks=game.currentClocks
                VStack(alignment:.leading,spacing:6){row(top,clocks:clocks);row(top.opponent,clocks:clocks)}
            }
        }
    }
    private func row(_ side:NetworkSide,clocks:NetworkClocks?)->some View {
        let colour=side == .white ? "white":"black",toMove=game.rules.turn==side.rawValue && game.outcome==nil
        return HStack(spacing:Metrics.smallGap){
            TurnIndicator(side:side.rawValue,label:side == .white ? "White":"Black")
            Text(game.players.name(side)+(side==game.learnerSide ? " (you)":"")).fontWeight(toMove ? .semibold:.regular).accessibilityIdentifier("network-\(colour)-name")
            Spacer(minLength:Metrics.smallGap)
            if let clocks {
                Text(Self.clock(clocks.remaining(side))).font(.system(.title3,design:.monospaced)).foregroundStyle(clocks.active==side ? .primary:.secondary)
                    .accessibilityLabel(Self.spokenClock(clocks.remaining(side))).accessibilityIdentifier("network-\(colour)-clock")
            }
        }
    }
    /// "4:05": whole seconds, rounded up so a clock reads 0:00 only once it has run out.
    static func clock(_ milliseconds:Int)->String {let seconds=(max(0,milliseconds)+999)/1000;return String(format:"%d:%02d",seconds/60,seconds%60)}
    static func spokenClock(_ milliseconds:Int)->String {
        let seconds=(max(0,milliseconds)+999)/1000,minutes=seconds/60,rest=seconds%60
        return [minutes>0 ? "\(minutes) minute\(minutes==1 ? "":"s")":nil,rest>0 || minutes==0 ? "\(rest) second\(rest==1 ? "":"s")":nil].compactMap{$0}.joined(separator:" ")
    }
}
/// The host sheet (D10): your name, side, time control and Allow Spectators.
struct NetworkHostSheet:View {
    @ObservedObject var game:NetworkGameController
    let close:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:Metrics.padding){
            Text("Host a Game").font(.title2.bold())
            Form {
                TextField("Your name",text:$game.playerName).accessibilityIdentifier("network-host-name")
                Picker("Your side",selection:$game.form.side){Text("White").tag(NetworkSideChoice.white);Text("Black").tag(NetworkSideChoice.black);Text("Random").tag(NetworkSideChoice.random)}.accessibilityIdentifier("network-host-side")
                Picker("Time control",selection:$game.form.timeControl){ForEach(NetworkTimeControl.allCases,id:\.self){control in Text(Self.label(control)).tag(control)}}.accessibilityIdentifier("network-host-time-control")
                Toggle("Allow spectators",isOn:$game.form.allowSpectators).accessibilityIdentifier("network-host-allow-spectators")
            }
            if let message=game.lobbyMessage{Text(message).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("network-host-message")}
            HStack {
                Spacer()
                Button("Cancel"){close()}.keyboardShortcut(.cancelAction).accessibilityIdentifier("network-host-cancel")
                Button("Host"){if game.host(){close()}}.keyboardShortcut(.defaultAction).disabled(!game.nameValid).accessibilityIdentifier("network-host-start")
            }
        }.padding(Metrics.sectionGap).frame(width:380).accessibilityElement(children:.contain).accessibilityIdentifier("network-host-sheet")
    }
    /// "Untimed", "5 + 3": minutes, plus seconds added per move.
    static func label(_ control:NetworkTimeControl)->String {
        guard let initial=control.initial else{return "Untimed"}
        return "\(initial.components.seconds/60) + \(control.increment.components.seconds)"
    }
}
