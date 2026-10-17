import SwiftUI
import CheckmateCore
/// The Play on Network pane beside the board (LAN-play plan D10): the lobby — Host a Game, and one list of found games
/// for Join and Watch — then the game's own chrome: the codes to share, names and clocks, the status, draw and hold
/// controls, Leave, and Review this game. The board area keeps its square board and centred title; nothing here is a
/// toolbar item. A game with assistance shows its terms, each side's hint count and, when allowed, the Hint button
/// (assistance plan A12).
struct NetworkDetail:View {
    @ObservedObject var model:NativeModel
    @ObservedObject var game:NetworkGameController
    @ObservedObject var assistant:NetworkAssistant
    @ObservedObject var voice:VoiceCoach
    @State private var chosen:String?
    /// The game whose assistance the Accept sheet asks about (A3).
    @State private var offered:NetworkDiscoveredGame?
    @State private var code=""
    @State private var hosting=false
    var body:some View {
        VStack(alignment:.leading,spacing:Metrics.smallGap){
            Text(game.title).font(.title2.bold()).accessibilityIdentifier("network-title")
            if game.part==nil{lobby}else{session}
            if let notice=game.notice{Text(notice).foregroundStyle(.secondary).accessibilityIdentifier("network-notice")}
        }
        .sheet(isPresented:$hosting){NetworkHostSheet(game:game,close:{hosting=false})}
        .sheet(item:Binding(get:{offered.map(OfferedGame.init)},set:{if $0==nil{offered=nil}})){shown in
            NetworkAcceptSheet(game:shown.game,accept:{offered=nil;game.join(shown.game,code:code,accepting:shown.game.assistance)},decline:{offered=nil})
        }
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
            let badge=NetworkWording.badge(entry.assistance)
            Button{chosen=entry.gameID.text}label:{
                HStack(spacing:Metrics.smallGap){
                    Label(entry.displayName,systemImage:selected ? "largecircle.fill.circle":"circle")
                    // A12: the advertised assistance, from the TXT record, for display only; joining checks the terms.
                    if let badge{Text(badge).font(.caption).padding(.horizontal,6).padding(.vertical,1).background(Capsule().fill(.quaternary))}
                }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(entry.displayName+(badge.map{", "+$0} ?? "")).accessibilityAddTraits(selected ? .isSelected:[]).accessibilityIdentifier("network-game-"+entry.gameID.text)
        }
        if let entry=game.games.first(where:{$0.gameID.text==chosen}) {
            TextField("Your name",text:$game.playerName).textFieldStyle(.roundedBorder).accessibilityIdentifier("network-name-field")
            TextField("Code",text:$code).textFieldStyle(.roundedBorder).accessibilityIdentifier("network-code-field")
            HStack {
                // A3: a seat in a game with assistance is joined only after its terms are accepted.
                Button("Join"){if entry.assistance == .off{game.join(entry,code:code)}else{offered=entry}}.disabled(entry.record(.seat)==nil || code.isEmpty).accessibilityIdentifier("network-join-button")
                Button("Watch"){game.join(entry,code:code,watching:true)}.disabled(entry.record(.watch)==nil || code.isEmpty).accessibilityIdentifier("network-watch-button")
            }
            Text("Join with the play code, or watch with the watch code.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
        if let message=game.lobbyMessage{Text(message).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("network-lobby-message")}
    }

    // MARK: Session
    @ViewBuilder private var session:some View {
        if game.part == .host,game.outcome==nil,game.sessionOpen,let play=game.playCode {codes(play)}
        if game.seat != nil {players;assistance;voiceCoach}
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
    /// The agreed terms, both sides' hint counts, and the learner's own Hint (A6, A7, A12).
    @ViewBuilder private var assistance:some View {
        if let record=game.record,let terms=NetworkWording.terms(record.assistance,players:game.players) {
            Text(terms).font(.callout).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("network-terms")
            if record.assistance.white >= .hints || record.assistance.black >= .hints {Text(NetworkWording.hintsUsed(record,players:game.players)).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("network-hints-used")}
        }
        if assistant.level >= .hints,game.outcome==nil {
            if let hint=assistant.hint {Text(NetworkWording.hint(san:hint.san,uci:hint.uci,automatic:hint.automatic)).font(.headline).accessibilityIdentifier("network-hint-text")}
            else if assistant.thinking {ProgressView(NetworkWording.findingHint).controlSize(.small).accessibilityIdentifier("network-hint-thinking")}
            else if game.yourTurn {Button("Hint"){assistant.ask()}.disabled(!assistant.canAsk).accessibilityIdentifier("network-hint-button")}
            if let error=assistant.error {Text(error).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("network-hint-error")}
        }
    }
    /// The voice coach for this network game (A10): offered only while the learner's level allows hints. The
    /// microphone follows Settings, as in Practice.
    @ViewBuilder private var voiceCoach:some View {
        if voice.networkVoiceAvailable,game.outcome==nil {
            if voice.connected,voice.networkSession {
                Text(voice.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("network-voice-status")
                HStack {
                    Button("Stop Speaking"){voice.stopTurn()}.disabled(!voice.canStopTurn).accessibilityIdentifier("network-voice-stop")
                    Button("Disconnect Coach"){voice.disconnect()}.accessibilityIdentifier("network-voice-disconnect")
                }
                ForEach(Array(voice.history.suffix(3).reversed())){entry in Text((entry.role=="learner" ? "You: ":"Coach: ")+entry.text).font(.caption).fixedSize(horizontal:false,vertical:true)}
            } else if voice.connecting {Button("Cancel Voice Coach"){voice.disconnect()}.accessibilityIdentifier("network-voice-cancel")}
            else {Button("Connect Voice Coach"){voice.connect()}.accessibilityIdentifier("network-voice-connect")}
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
/// A discovered game as a sheet's item: the Accept sheet is tied to the game it was opened for.
private struct OfferedGame:Identifiable {
    let game:NetworkDiscoveredGame
    var id:String {game.gameID.text}
}
/// The Accept sheet (assistance plan A3): a seat in a game with assistance is taken only after its terms are accepted.
/// Decline goes back to the list.
struct NetworkAcceptSheet:View {
    let game:NetworkDiscoveredGame
    let accept:()->Void,decline:()->Void
    var body:some View {
        VStack(alignment:.leading,spacing:Metrics.padding){
            Text("Join \(game.displayName)?").font(.title2.bold())
            Text(NetworkWording.offer(game.assistance,game:game.name)).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("network-accept-terms")
            Text("The assistance stays the same for the whole game, and each Mac counts the hints its player uses.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                Spacer()
                Button("Decline"){decline()}.keyboardShortcut(.cancelAction).accessibilityIdentifier("network-decline-assistance")
                Button("Accept and Join"){accept()}.keyboardShortcut(.defaultAction).accessibilityIdentifier("network-accept-assistance")
            }
        }.padding(Metrics.sectionGap).frame(width:380).accessibilityElement(children:.contain).accessibilityIdentifier("network-accept-sheet")
    }
}
/// The host sheet (D10): your name, side, time control and Allow Spectators, and the assistance both players agree to
/// (assistance plan A2): one level for both, or a handicap with a level for each side.
struct NetworkHostSheet:View {
    @ObservedObject var game:NetworkGameController
    let close:()->Void
    @State private var handicap=false
    var body:some View {
        VStack(alignment:.leading,spacing:Metrics.padding){
            Text("Host a Game").font(.title2.bold())
            Form {
                TextField("Your name",text:$game.playerName).accessibilityIdentifier("network-host-name")
                Picker("Your side",selection:$game.form.side){Text("White").tag(NetworkSideChoice.white);Text("Black").tag(NetworkSideChoice.black);Text("Random").tag(NetworkSideChoice.random)}.accessibilityIdentifier("network-host-side")
                Picker("Time control",selection:$game.form.timeControl){ForEach(NetworkTimeControl.allCases,id:\.self){control in Text(Self.label(control)).tag(control)}}.accessibilityIdentifier("network-host-time-control")
                Toggle("Allow spectators",isOn:$game.form.allowSpectators).accessibilityIdentifier("network-host-allow-spectators")
                if handicap {
                    levels("White's assistance",\.white,"network-host-assistance-white")
                    levels("Black's assistance",\.black,"network-host-assistance-black")
                }else{
                    Picker("Assistance",selection:Binding(get:{game.form.assistance.white},set:{game.form.assistance=NetworkAssistance(both:$0)})){ForEach(NetworkAssistanceLevel.allCases,id:\.self){level in Text(level.title).tag(level)}}.accessibilityIdentifier("network-host-assistance")
                }
                // Turning the handicap off gives Black White's level again: the terms are one level for both by default.
                Toggle("Handicap: different assistance for each side",isOn:Binding(get:{handicap},set:{handicap=$0;if !$0{game.form.assistance=NetworkAssistance(both:game.form.assistance.white)}})).accessibilityIdentifier("network-host-handicap")
            }
            if let message=game.lobbyMessage{Text(message).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("network-host-message")}
            HStack {
                Spacer()
                Button("Cancel"){close()}.keyboardShortcut(.cancelAction).accessibilityIdentifier("network-host-cancel")
                Button("Host"){if game.host(){close()}}.keyboardShortcut(.defaultAction).disabled(!game.nameValid).accessibilityIdentifier("network-host-start")
            }
        }.padding(Metrics.sectionGap).frame(width:380).accessibilityElement(children:.contain).accessibilityIdentifier("network-host-sheet").onAppear{handicap=game.form.assistance.handicap}
    }
    private func levels(_ title:String,_ side:WritableKeyPath<NetworkAssistance,NetworkAssistanceLevel>,_ identifier:String)->some View {
        Picker(title,selection:Binding(get:{game.form.assistance[keyPath:side]},set:{game.form.assistance[keyPath:side]=$0})){ForEach(NetworkAssistanceLevel.allCases,id:\.self){level in Text(level.title).tag(level)}}.accessibilityIdentifier(identifier)
    }
    /// "Untimed", "5 + 3": minutes, plus seconds added per move.
    static func label(_ control:NetworkTimeControl)->String {
        guard let initial=control.initial else{return "Untimed"}
        return "\(initial.components.seconds/60) + \(control.increment.components.seconds)"
    }
}
