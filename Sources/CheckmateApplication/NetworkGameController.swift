import CheckmateDomain
import CheckmateRules
import CheckmateSupport
import Combine
import Foundation
import OSLog
/// The network game (LAN-play plan D9, D10): one session at a time — hosting, a guest's seat, or watching — and the
/// game it shows, on its own board model (`NetworkBoardModel`, chess so far), never practice's, with its own input. Board clicks, drags and the promotion
/// choice in the network place come here; practice, lessons and reviews never see them.
///
/// The host runner or the client runner does the networking on the services' queue; their events reach this controller
/// on the main actor, in order, and an event from an earlier session is dropped. A move the learner makes is submitted
/// once and shown pending ("Sending…") until the game answers (D2): the board changes only when the move is applied,
/// and further presses are ignored meanwhile.
///
/// Participation (D8) begins when the learner is seated, watching, or hosting a game whose seat is taken, and ends at
/// the result, on Leave, or when the session stops. While it lasts the crash file holds the public record (D9).
@MainActor public final class NetworkGameController:ObservableObject {
    /// The learner's part in the shown game: a side to play, or watching.
    public enum Seat:Equatable {case player(side:String),spectator}
    /// A submitted move awaiting the game's answer: the lifted piece and its target square.
    public struct PendingMove:Equatable {public let from:String,to:String,uci:String}
    /// The session the learner is in.
    public enum Part:Equatable {case host,guest,spectator}
    /// Where the session's connection stands.
    public enum Link:Equatable {
        /// Joining or watching, before the host's game arrives.
        case connecting
        /// macOS denied local-network access; the connection goes on by itself once it is granted (D11).
        case denied
        /// The host: listeners open, nobody seated yet.
        case waiting
        case live
        /// The host: the guest dropped and the seat is held (D4).
        case away
        /// A guest or spectator: the connection dropped and is being regained within the hold.
        case reconnecting
        /// Nothing more will happen. A game that was shown stays on the board, for Review.
        case stopped
    }
    /// The sidebar badge while the learner is elsewhere and the game waits for their move (D9).
    public static let yourMoveBadge="Network game · your move"
    public static let lobbyTitle="Play on Network"
    public static let nameNeeded="Type your name first, up to 64 characters."
    public static let codeNeeded="Type the 8-character code shown on the host's Mac."
    /// Joining a game with assistance needs the person to accept its terms first (assistance plan A3).
    public static let assistanceNeeded="Accept this game's assistance to join it."
    public static let leaveConfirmation="Leave the game? It counts as a resignation."
    public static let watchingNotice="You're watching"
    /// Hosting refused the chosen start (mini-games plan D7).
    public static let startOver="That position is already over. Choose a different move."
    public static let startIllegal="That position can't start a game. Choose a different move."
    public static let sendingNotice="Sending…"

    // MARK: The shown game
    /// The shown game (mini-games plan WI-022): this controller and the views read it only through the board model.
    public private(set) var rules:any NetworkBoardModel
    @Published public private(set) var seat:Seat?
    @Published public private(set) var board:Position=[:]
    @Published public private(set) var selected:String?
    @Published public private(set) var destinations:[String]=[]
    @Published public private(set) var pending:PendingMove?
    /// A short notice on the board: "You're watching" after a spectator's click, "Sending…" while a move is pending,
    /// or why a command was refused.
    @Published public private(set) var notice:String?
    @Published public private(set) var title=NetworkGameController.lobbyTitle
    /// Advances whenever the shown game or position changes; display identities and late answers are tied to it.
    public private(set) var revision=0
    /// Hands a move to a game shown without a session (`show`); a session's own moves go to its runner.
    public var submit:(String)->Void={_ in}
    /// White sits at the bottom unless the learner plays Black; Flip Board turns it round.
    @Published public private(set) var flipped=false

    // MARK: The session
    @Published public private(set) var part:Part?
    /// "Ana's game": the hosted game's name, as joiners see it.
    @Published public private(set) var gameName=""
    @Published public private(set) var link:Link = .stopped
    /// The host's own phase (D4); nil for a guest or spectator.
    @Published public private(set) var hostPhase:NetworkHostPhase?
    /// The codes the host shares, shown grouped for reading ("K7QD-2M9X"). The watch code only when spectators may watch.
    @Published public private(set) var playCode:NetworkCode?
    @Published public private(set) var watchCode:NetworkCode?
    @Published public private(set) var whiteName:String?
    @Published public private(set) var blackName:String?
    @Published public private(set) var timeControl:NetworkTimeControl = .untimed
    @Published public private(set) var openOffer:NetworkDrawOffer?
    @Published public private(set) var outcome:NetworkOutcome?
    /// The host: the guest has been away past the hold; offer Claim Win or Keep Waiting (D4).
    @Published public private(set) var holdExpired=false
    @Published public private(set) var spectators:[String]=[]
    /// Why the session stopped, in plain words (D11); nil while it runs, after a result, and after leaving.
    @Published public private(set) var stopMessage:String?
    /// The side the learner plays; nil for a spectator.
    @Published public private(set) var learnerSide:NetworkSide?
    /// The last public record shown: what Review and the crash file use (D9).
    public private(set) var record:NetworkPublicGame?
    /// The game's own revision (D2), as last shown.
    public private(set) var gameRevision:Int?

    // MARK: The lobby
    /// Games found on the network, each shown as "Ana's game · K7QD" (D3).
    @Published public private(set) var games:[NetworkDiscoveredGame]=[]
    @Published public private(set) var browsing=false
    /// B-26: this look has found no game in `browseTimeout`; the lobby points to the Local Network setting. A game
    /// found clears it, and each new look starts the time again.
    @Published public private(set) var browseTimedOut=false
    public static let browseTimeout:Duration = .seconds(10)
    public static let browseTimeoutHelp="No games found. If a game is open on another Mac, check that Checkmate is allowed in System Settings ▸ Privacy & Security ▸ Local Network."
    /// One of D11's two denial signals was seen and access has not come back since.
    @Published public private(set) var localNetworkDenied=false
    /// Show the permission help (D11), until dismissed or access comes back.
    @Published public private(set) var permissionHelp=false
    @Published public private(set) var lobbyMessage:String?
    /// The name sent to the other Macs: the host's on its game, a guest's or spectator's in `hello`.
    @Published public var playerName:String
    @Published public var form=NetworkHostForm()

    /// The app's network services; nil where no session can start (a game shown with `show` only).
    public var services:NetworkServices?
    /// The app's participation, which this controller begins and ends (D8); nil in tests of the board alone.
    public let participation:NetworkParticipation?
    /// VoiceOver: the window posts each announcement (D10).
    public var announce:(String)->Void={_ in}
    /// Runs after every event has settled participation and the shown game: the network assistant follows the turn here
    /// (assistance plan A6).
    public var onSettle:()->Void={}

    private enum Runner {case host(NetworkHostRunner,NetworkHostingConfiguration),client(NetworkClientRunner)}
    private var runner:Runner?
    private var sessionNumber=0,browseNumber=0,clockWatch=0,flashNumber=0
    private var shown=false,detached=false,leaving=false,seated=false,watching=false,everLive=false,permissionDismissed=false
    private var pendingRevision:Int?,pendingSeen=false
    private var shownPGN:String?
    private var clockSync:(clocks:NetworkClocks,at:NetworkInstant)?
    private var clockSeen:[NetworkSide:Int]=[:]
    /// The lowest threshold announced for each side since its clock was last clearly above it.
    private var clockAnnounced:[NetworkSide:Int]=[:]
    /// How far above an announced threshold a reading must be to count as an increment, not a re-sync.
    private static let clockSlack=500
    private var participating:NetworkParticipation.Role?
    private var participatingAssistance:NetworkAssistanceLevel = .off
    /// The last record's moves could not be shown: the board is behind the game, so it takes no move and no help
    /// until a record that loads arrives.
    private var recordUnreadable=false,retryingRecord=false
    /// The clock announcement waiting for its threshold; each reading replaces it, so one is ever pending.
    private var clockAlarm:NetworkScheduledWork?
    /// The time limit of the current look; cancelled when the lobby stops looking.
    private var browseAlarm:NetworkScheduledWork?
    /// What the waiting alarm is for: the side, the threshold it announces, and when.
    private var clockAlarmTarget:(side:NetworkSide,threshold:Int,due:NetworkInstant)?
    /// The game revision of the turn in which a hint was shown to the learner (A7); their move in that turn says so.
    private var assistedTurn:Int?
    /// The record last written to the crash file, without its clocks.
    private var savedRecord:NetworkPublicGame?
    private var leaveCompletions:[@MainActor ()->Void]=[]

    public init(services:NetworkServices?=nil,participation:NetworkParticipation?=nil,playerName:String="")throws {
        rules=try Self.newBoard();self.services=services;self.participation=participation;self.playerName=playerName
        miniReview.currentNetwork={[weak self] in
            guard let self,let game=self.rules as? NetworkMiniGame,let ruleset=game.ruleset,self.outcome != nil else{return nil}
            return (self.sessionNumber,ruleset.kind,(try? game.networkMoves())?.map{MiniGameMove(from:String($0.prefix(2)),to:String($0.suffix(2)))} ?? [])
        }
        // The pane shows the review's progress, so a change of it is a change of this game's.
        reviewWatch=miniReview.objectWillChange.sink{[weak self] _ in self?.objectWillChange.send()}
    }
    private var reviewWatch:AnyCancellable?
    /// The shown game's model: chess, or a mini-game's referee for a ruleset game (protocol 1.3). The crash notice's
    /// Review replays its record on one too.
    nonisolated public static func newBoard(_ ruleset:NetworkRuleset?=nil)throws -> any NetworkBoardModel {try ruleset.map{NetworkMiniGame($0)} ?? ChessRules()}
    /// The mini-game the shown game is played by, as verified; nil for chess.
    public var ruleset:NetworkRuleset? {rules.ruleset}
    /// The review of a finished network mini-game (protocol 1.3, WI-018's proof search): it starts when the verified
    /// result arrives and its sheet opens when the learner asks. The network place's own, never the lesson's.
    public let miniReview=MiniGameReviewer()
    public var fen:String? {seat==nil ? nil:rules.fen}
    public var identity:String {seat==nil ? "lobby":"game:\(revision)"}
    public var blackAtBottom:Bool {(seat == .player(side:"b")) != flipped}
    public var side:String? {if case .player(let side)=seat{return side};return nil}
    public var players:NetworkWording.Players {NetworkWording.Players(white:whiteName,black:blackName,learner:learnerSide)}
    /// The other player's name, as the learner reads it.
    public var opponentName:String {learnerSide.map{players.name($0.opponent)} ?? "Your opponent"}

    // MARK: A game shown without a session
    /// Shows a game: the seat the learner holds and the position (a record the host's game has already verified).
    /// Moves go to `submit`.
    public func show(seat:Seat,title:String,pgn:String)throws {
        try load(pgn,ruleset:nil);recordUnreadable=false;self.seat=seat;self.title=title;detached=true;pending=nil
        if case .player(let side)=seat{learnerSide=NetworkSide(rawValue:side)}else{learnerSide=nil}
        resetInput();changed()
    }
    /// The lobby again: no game on the board.
    public func clear(){seat=nil;detached=false;title=Self.lobbyTitle;try? load("",ruleset:nil);recordUnreadable=false;resetInput();changed()}
    /// A move the game applied, the learner's own or the opponent's. It clears a pending move it answers.
    public func applied(uci:String)throws {try rules.move(uci:uci);if pending?.uci==uci{pending=nil};resetInput();changed()}
    /// The game refused the pending move: the piece goes back, nothing else changes.
    public func rejected(){pending=nil;notice=nil;selected=nil;destinations=[];objectWillChange.send()}
    /// Loads a record on the board model of its game: chess, or the ruleset's referee. A record that does not load leaves
    /// the board as it was, whichever model it needed.
    private func load(_ pgn:String,ruleset:NetworkRuleset?)throws {
        let board=ruleset==rules.ruleset ? rules:try Self.newBoard(ruleset)
        if pgn.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty{try board.loadStart()}else{try board.restore(pgn)}
        rules=board
    }
    private func resetInput(){selected=nil;destinations=[];if pending==nil{notice=nil}else{notice=Self.sendingNotice}}
    private func changed(){revision+=1;board=seat==nil ? [:]:rules.board;objectWillChange.send()}

    // MARK: Input
    /// Moves are taken only in a running game: the host's once the guest is seated, a guest's while live (D4).
    private var inputOpen:Bool {
        guard !recordUnreadable else{return false}
        switch part {
        case nil:return detached
        case .host?:return runner != nil && hostPhase == .running && outcome==nil && !leaving
        case .guest?:return link == .live && outcome==nil && !leaving
        case .spectator?:return false
        }
    }
    /// It is the learner's move in a running game, with none already on its way. Once a move is sent the turn is
    /// over for help too (assistance plan A7): its `assisted` flag went with it, so no hint or coach turn may follow.
    public var yourTurn:Bool {guard pending==nil,let side,inputOpen,!rules.over else{return false};return rules.turn==side}
    /// Whether it is the learner's move now, with nothing pending.
    public var canMove:Bool {yourTurn}
    /// "Network game · your move", for the sidebar while the learner is elsewhere.
    public var badge:String? {yourTurn ? Self.yourMoveBadge:nil}
    public func canDrag(_ square:String)->Bool {canMove && rules.piece(square)?.color==side}
    public func needsPromotion(from:String,to:String)->Bool {rules.needsPromotion(from:from,to:to)}
    /// A click: a spectator is told they are watching; a player selects a piece of theirs, or plays to a dot.
    public func click(_ square:String){
        guard ChessNotation.validSquare(square),seat != nil else{return}
        if seat == .spectator{flash(Self.watchingNotice);return}
        // Clicking the selected square again clears the selection, as in practice and training.
        if selected==square{selected=nil;destinations=[];objectWillChange.send();return}
        // Board insight (assistance plan A1) lets the learner pick any piece to inspect, also off their turn; it never
        // shows dots for a move they cannot make.
        guard canMove else{guard inspectable,pending==nil else{return};selected=rules.piece(square)==nil ? nil:square;destinations=[];objectWillChange.send();return}
        if let from=selected,destinations.contains(square){play(from:from,to:square);return}
        if rules.piece(square)?.color==side{selected=square;destinations=Array(Set(rules.moves(square).map(\.to))).sorted()}
        else if inspectable,rules.piece(square) != nil{selected=square;destinations=[]}
        else{selected=nil;destinations=[]}
        objectWillChange.send()
    }
    /// The piece inspector (Protected by / Attacked by) works on this board (A1, A8): a seated player whose agreed level
    /// is board insight or more. Never a spectator, never once the game is over, and never on a board behind its record.
    public var inspectable:Bool {side != nil && !recordUnreadable && participation?.role == .player && (participation?.assistance ?? .off) >= .insight}
    /// Escape on the board: the selected piece and its dots go, so a later click on a former dot plays nothing.
    public func clearSelection(){guard selected != nil || !destinations.isEmpty else{return};selected=nil;destinations=[];objectWillChange.send()}
    /// Submits one move; anything illegal, or a second move while one is pending, is ignored.
    public func play(from:String,to:String,promotion:String="q"){
        guard canMove,let move=rules.moves(from).first(where:{$0.to==to && ($0.promotion==nil || $0.promotion==promotion)}) else{return}
        // A7: read before the move is pending, which ends the turn's help.
        let uci=move.uci,session=sessionNumber,assisted=assistedThisTurn
        pending=PendingMove(from:from,to:to,uci:move.uci);pendingRevision=gameRevision;pendingSeen=false
        selected=nil;destinations=[];notice=Self.sendingNotice;objectWillChange.send()
        // The turn's help ends now (A7): the assistant drops its hint and search without waiting for the runner.
        onSettle()
        switch runner {
        case .host(let runner,_)?:runner.perform(.move(uci:uci,assisted:assisted))
        case .client(let runner)?:runner.submitMove(uci:uci,assisted:assisted)
        case nil:submit(uci);return
        }
        // By now the queue has handled the move and its answer has been delivered: a press it ignored (the game moved
        // on, the link dropped) left no trace, so the piece goes back.
        afterQueue{[weak self] in
            guard let self,self.sessionNumber==session,self.pending?.uci==uci,!self.pendingSeen,self.gameRevision==self.pendingRevision else{return}
            self.clearPending()
        }
    }
    private func clearPending(){
        guard pending != nil else{return}
        defer{onSettle()}
        pending=nil;pendingRevision=nil;pendingSeen=false;if notice==Self.sendingNotice{notice=nil}
    }
    /// The board area's centred title, with the notice after it while one shows ("Ana vs Ben · You're watching"), so
    /// it is seen with the details drawer closed too.
    public var boardTitle:String {notice.map{"\(title) · \($0)"} ?? title}
    /// A notice that clears itself after a moment; VoiceOver hears it too.
    private func flash(_ text:String){
        flashNumber+=1;let number=flashNumber;notice=text;announce(text)
        DispatchQueue.main.asyncAfter(deadline:.now()+2.5){[weak self] in MainActor.assumeIsolated{
            guard let self,self.flashNumber==number,self.notice==text else{return}
            self.notice=self.pending==nil ? nil:Self.sendingNotice
        }}
    }
    public func flip(){guard seat != nil else{return};flipped.toggle();changed()}
    /// Runs `work` on the main actor after everything already on the network queue has run and what it reported has
    /// been delivered: the queue and the delivery are both first in, first out.
    private func afterQueue(_ work:@escaping @MainActor ()->Void){guard let services else{return};Self.after(services.scheduler,services.delivery,work)}
    // Closures that run on the network queue are made here, outside the main actor: a closure written inside a
    // main-actor method would be isolated to the main actor wherever it runs.
    nonisolated private static func relay<Event>(_ delivery:NetworkDelivery,_ handle:@escaping @MainActor (Event)->Void)->(Event)->Void {{event in delivery{handle(event)}}}
    nonisolated private static func after(_ scheduler:any NetworkScheduler,_ delivery:NetworkDelivery,_ work:@escaping @MainActor ()->Void){scheduler.enqueue{delivery(work)}}
    @discardableResult nonisolated private static func alarm(_ scheduler:any NetworkScheduler,at deadline:NetworkInstant,_ delivery:NetworkDelivery,_ work:@escaping @MainActor ()->Void)->NetworkScheduledWork {scheduler.schedule(at:deadline){delivery(work)}}
    nonisolated private static func browse(_ discovery:any NetworkDiscovery,on scheduler:any NetworkScheduler,_ updates:@escaping (NetworkDiscoveryUpdate)->Void){scheduler.enqueue{discovery.start(updates)}}
    nonisolated private static func stopBrowsing(_ discovery:any NetworkDiscovery,on scheduler:any NetworkScheduler){scheduler.enqueue{discovery.stop()}}

    // MARK: Lobby
    /// Whether the network place is on screen: the lobby browses only then, and never once a game is chosen (D1).
    public func setShown(_ shown:Bool){self.shown=shown;refreshBrowsing()}
    private func refreshBrowsing(){
        let wanted=shown && part==nil && services != nil
        guard wanted != browsing,let services else{return}
        browseNumber+=1;browsing=wanted
        if wanted {
            let number=browseNumber
            Self.browse(services.discovery,on:services.scheduler,Self.relay(services.delivery){[weak self] (update:NetworkDiscoveryUpdate) in self?.discovered(update,browse:number)})
            browseAlarm=Self.alarm(services.scheduler,at:services.scheduler.now+Self.browseTimeout,services.delivery){[weak self] in self?.browseLimitReached(number)}
        }else{
            Self.stopBrowsing(services.discovery,on:services.scheduler)
            if let alarm=browseAlarm{browseAlarm=nil;services.scheduler.enqueue{alarm.cancel()}}
            if !games.isEmpty{games=[]};if browseTimedOut{browseTimedOut=false}
        }
    }
    private func browseLimitReached(_ browse:Int){
        guard browse==browseNumber,browsing else{return}
        browseAlarm=nil;if games.isEmpty,!browseTimedOut{browseTimedOut=true;announce(Self.browseTimeoutHelp)}
    }
    private func discovered(_ update:NetworkDiscoveryUpdate,browse:Int){
        guard browse==browseNumber,browsing else{return}
        switch update {
        case .games(let found):if games != found{games=found};if lobbyMessage != nil{lobbyMessage=nil};if !found.isEmpty,browseTimedOut{browseTimedOut=false};accessRestored()
        case .denied:askForPermission()
        case .failed(let detail):NativeLog.lifecycle.error("Network discovery failed: \(detail,privacy:.public)");lobbyMessage="Couldn't look for games on your network."
        }
    }
    /// D11's denial signals only: a browser waiting with -65570, or a connection waiting with `localNetworkDenied`.
    private func askForPermission(){if !localNetworkDenied{localNetworkDenied=true};if !permissionDismissed,!permissionHelp{permissionHelp=true}}
    private func accessRestored(){guard localNetworkDenied else{return};localNetworkDenied=false;permissionHelp=false;permissionDismissed=false}
    public func dismissPermissionHelp(){permissionHelp=false;permissionDismissed=true}
    public var nameValid:Bool {Self.validName(playerName) != nil}
    static func validName(_ text:String)->String? {let name=text.trimmingCharacters(in:.whitespacesAndNewlines);return NetworkText.valid(name) ? name:nil}
    /// What a hosted game is called on the network: "Ana's game".
    public static func gameName(host:String)->String {"\(host)'s game"}

    // MARK: Starting a session
    /// Hosts a game with the sheet's settings (D10) and opens its listeners; false, with `lobbyMessage`, if it cannot.
    @discardableResult public func host()->Bool {
        guard part==nil,let services else{return false}
        guard let name=Self.validName(playerName) else{lobbyMessage=Self.nameNeeded;return false}
        let random=services.random,side=form.side.resolved(using:random)
        let gameID=NetworkGameID.random(using:random),seatCode=NetworkCode.random(using:random),watch=form.allowSpectators ? NetworkCode.random(using:random):nil
        let host:NetworkHost
        // Protocol 1.3: a mini-game only while its feature is on; it has its own start and no assistance.
        let ruleset=NetworkPolicy.miniGamesEnabled ? form.miniGame.flatMap(NetworkRuleset.init):nil
        // D7: a declared start only while the feature is on; otherwise the standard start, exactly as 1.1 hosts.
        let start=ruleset==nil && NetworkPolicy.positionsEnabled ? form.start?.fen:nil,assistance=ruleset==nil ? form.assistance:.off
        do{host=try NetworkHost(gameID:gameID,runEpoch:services.runEpoch,settings:NetworkHostSettings(hostName:name,hostSide:side,timeControl:form.timeControl,allowSpectators:form.allowSpectators,assistance:assistance,startFEN:start,ruleset:ruleset),rules:services.rules,hashing:services.hashing,random:random,at:services.scheduler.now)}
        catch NetworkHostError.startOver{lobbyMessage=Self.startOver;return false}
        catch NetworkHostError.illegalStart{lobbyMessage=Self.startIllegal;return false}
        catch{NativeLog.lifecycle.error("A network game could not be set up: \(String(describing:error),privacy:.public)");lobbyMessage="The game could not be set up.";return false}
        let configuration=NetworkHostingConfiguration(gameID:gameID,seatCode:seatCode,watchCode:watch,serviceName:Self.gameName(host:name),assistance:assistance,variant:ruleset?.descriptor)
        beginSession(.host,name:configuration.serviceName)
        playCode=seatCode;watchCode=watch;learnerSide=side;timeControl=form.timeControl;hostPhase = .waiting
        if side == .white{whiteName=name}else{blackName=name}
        // The board shows the game's own start at once, before the first status: the standard one, or the declared one.
        try? load((try? host.publicGame(at:services.scheduler.now).pgn) ?? "",ruleset:ruleset);seat = .player(side:side.rawValue);changed()
        let session=sessionNumber
        let runner=NetworkHostRunner(host:host,configuration:configuration,transport:services.transport,scheduler:services.scheduler,events:Self.relay(services.delivery){[weak self] (event:NetworkHostRunner.Event) in self?.hosted(event,session:session)})
        self.runner = .host(runner,configuration);runner.start();settle()
        return true
    }
    /// Joins a found game's seat with its play code, or watches it with its watch code (D3: only the code is typed;
    /// everything else comes from the chosen record). False, with `lobbyMessage`, if it cannot start.
    ///
    /// A seat is joined only under terms the person accepted (assistance plan A3): `accepting` must be the terms the
    /// game advertises, unless it advertises none. The guest states them in `hello`, and both sides check them again.
    @discardableResult public func join(_ game:NetworkDiscoveredGame,code typed:String,watching:Bool=false,accepting:NetworkAssistance?=nil)->Bool {
        guard part==nil,let services else{return false}
        let role:NetworkListenerRole=watching ? .watch:.seat,name=game.name.isEmpty ? "the host's game":game.name
        guard let record=game.record(role) else{lobbyMessage=watching ? "\(name) doesn't allow spectators.":"\(name) has no seat to join.";return false}
        guard let player=Self.validName(playerName) else{lobbyMessage=Self.nameNeeded;return false}
        guard let code=NetworkCode(typed:typed) else{lobbyMessage=Self.codeNeeded;return false}
        let accepted=accepting ?? .off
        guard watching || accepted==game.assistance else{lobbyMessage=Self.assistanceNeeded;return false}
        beginSession(watching ? .spectator:.guest,name:name)
        let receiver=NetworkReceiver(gameID:game.gameID,role:watching ? .spectator:.guest(claimID:.random(using:services.random)),name:player,appVersion:services.appVersion,rules:services.rules,hashing:services.hashing,random:services.random,accepting:watching ? .off:accepted)
        connect(receiver,endpoint:record.endpoint,key:game.key(role,code:code),services:services)
        return true
    }
    private func connect(_ receiver:NetworkReceiver,endpoint:NetworkEndpoint,key:NetworkAccessKey,services:NetworkServices){
        let session=sessionNumber
        let runner=NetworkClientRunner(receiver:receiver,endpoint:endpoint,key:key,transport:services.transport,scheduler:services.scheduler,events:Self.relay(services.delivery){[weak self] (event:NetworkClientRunner.Event) in self?.connected(event,session:session)})
        resumable=(receiver,endpoint,key);self.runner = .client(runner);runner.start();settle()
    }
    /// The connection given up after the game was live ("Couldn't reach Ana's game") can be tried again, resuming the
    /// same seat with the credential this receiver still holds: D4 keeps resume valid for as long as the host keeps
    /// waiting, longer than the guest's own reconnect window.
    public var canTryAgain:Bool {runner==nil && retryable && resumable != nil && outcome==nil && !leaving}
    public func tryAgain(){
        guard canTryAgain,let services,let (receiver,endpoint,key)=resumable else{return}
        stopMessage=nil;retryable=false;link = .connecting;objectWillChange.send()
        connect(receiver,endpoint:endpoint,key:key,services:services)
    }
    private var resumable:(receiver:NetworkReceiver,endpoint:NetworkEndpoint,key:NetworkAccessKey)?
    private var retryable=false
    private func beginSession(_ part:Part,name:String){
        sessionNumber+=1;resetSession();self.part=part;gameName=name;link = part == .host ? .waiting:.connecting;lobbyMessage=nil
        refreshBrowsing()
    }
    private func resetSession(){
        leaving=false;seated=false;watching=false;everLive=false;detached=false
        pending=nil;pendingRevision=nil;pendingSeen=false;shownPGN=nil;clockSync=nil;clockSeen=[:];clockAnnounced=[:];record=nil;gameRevision=nil
        gameName="";link = .stopped;hostPhase=nil;playCode=nil;watchCode=nil;whiteName=nil;blackName=nil;timeControl = .untimed
        openOffer=nil;outcome=nil;holdExpired=false;spectators=[];stopMessage=nil;learnerSide=nil;flipped=false;notice=nil;selected=nil;destinations=[]
        resumable=nil;retryable=false;sleptWhileHosting=false;assistedTurn=nil;miniReview.cancel()
    }
    /// Back to the lobby: the session is over and forgotten.
    private func endSession(){
        sessionNumber+=1;runner=nil;resetSession();part=nil;seat=nil;title=Self.lobbyTitle;try? load("",ruleset:nil);changed();settle();refreshBrowsing()
    }

    // MARK: Events
    private func hosted(_ event:NetworkHostRunner.Event,session:Int){
        guard session==sessionNumber,case .host(_,let configuration)?=runner else{return}
        switch event {
        case .listening(let endpoints):services?.listenersReady(configuration,endpoints)
        case .status(let status):
            update(\.hostPhase,status.phase);update(\.holdExpired,status.holdExpired);update(\.spectators,status.spectators)
            update(\.link,status.phase == .waiting ? .waiting:status.phase == .disconnected ? .away:.live)
            present(status.game,at:status.at)
        case .refused(let reason):clearPending();flash(NetworkWording.refusal(reason))
        case .stopped(let stop):
            runner=nil;update(\.link,.stopped);clearPending();services?.listenersClosed(configuration.gameID)
            if case .failed(let detail)=stop {NativeLog.lifecycle.error("The hosted network game stopped: \(detail,privacy:.public)");if !leaving{stopMessage=sleptWhileHosting ? "Your game stopped when this Mac went to sleep.":"Your game had to stop."}}
            if leaving{return finishLeaving()}
        }
        settle()
    }
    private func connected(_ event:NetworkClientRunner.Event,session:Int){
        guard session==sessionNumber,runner != nil else{return}
        switch event {
        case .receiver(.seated),.receiver(.resumed):seated=true
        case .receiver(.watching):watching=true
        // The refusal says why; whether it was this Mac's pending move follows from the status, which clears the move
        // only when the receiver let it go, so a refused draw offer never reopens a move already sent (A7).
        case .receiver(.rejected(_,let reason)):flash(NetworkWording.refusal(reason))
        case .receiver:break
        case .status(let status):
            switch status.link {
            case .connecting:update(\.link,.connecting)
            case .denied:update(\.link,.denied);askForPermission()
            case .live:update(\.link,.live);everLive=true
            case .reconnecting:update(\.link,.reconnecting)
            case .stopped(let stop):
                retryable=stop == .couldNotReach && everLive;runner=nil;update(\.link,.stopped)
                if case .failed(let detail)=stop{NativeLog.lifecycle.error("A network game connection failed: \(detail,privacy:.public)")}
                if !leaving{stopMessage=NetworkWording.stop(stop,game:gameName,wasLive:everLive)}
            }
            if status.link != .denied{accessRestored()}
            if let side=status.side,learnerSide != side{learnerSide=side}
            if let game=status.game{present(game,at:status.at)}
            // D2: a pending move clears once the guest's game has seen it and let it go (rejected, a snapshot, a
            // reconnect), or when the game moves on.
            if let move=status.pendingMove,move.uci==pending?.uci{pendingSeen=true}else if status.pendingMove==nil,pendingSeen{clearPending()}
            if link != .live{clearPending()}
            if link == .stopped,leaving{return finishLeaving()}
        }
        settle()
    }
    /// A public record, from the host's own game or a verified snapshot: names, clocks, the open offer, the result, and
    /// the board when the moves changed. Announces what a sighted player would see happen.
    func present(_ game:NetworkPublicGame,at instant:NetworkInstant){
        let previousOffer=openOffer,previousOutcome=outcome,plies=rules.history.count,first=record==nil
        // The record is taken only once its moves load: one that cannot be shown leaves the last good record, revision
        // and board in place (crash file, Review, help) and stops input until a record that loads arrives.
        var reloaded=false
        // The record's ruleset is verified (the host's own settings, or a snapshot this Mac checked and pinned).
        let ruleset=game.ruleset.flatMap{NetworkRuleset(descriptor:$0)}
        if game.pgn != shownPGN || ruleset != rules.ruleset {
            do{try load(game.pgn,ruleset:ruleset)}
            catch{
                recordUnreadable=true;NativeLog.lifecycle.error("A network game record could not be shown: \(String(describing:error),privacy:.public)");resetInput()
                // An unchanged record is not sent again, so the same one gets one more try once the queue has run; if
                // that fails too, the learner is told rather than left on a board that takes no input.
                if retryingRecord{notice=NetworkWording.recordUnreadable;announce(NetworkWording.recordUnreadable)}
                else{let session=sessionNumber;afterQueue{[weak self] in guard let self,self.sessionNumber==session,self.recordUnreadable,self.shownPGN != game.pgn else{return};self.retryingRecord=true;defer{self.retryingRecord=false};self.present(game,at:instant)}}
                changed();return
            }
            shownPGN=game.pgn;recordUnreadable=false;reloaded=true
        }else if recordUnreadable{recordUnreadable=false;if notice==NetworkWording.recordUnreadable{notice=nil};objectWillChange.send()}
        record=game;gameRevision=game.revision;clockSync=game.clocks.map{($0,instant)}
        update(\.whiteName,game.whiteName);update(\.blackName,game.blackName);update(\.timeControl,game.timeControl);update(\.openOffer,game.openOffer);update(\.outcome,game.outcome)
        if seat==nil,let mine=learnerSeat{seat=mine}
        let moved=reloaded && rules.history.count != plies
        if reloaded {
            resetInput();changed()
            // A12: a move its mover made with a hint shown says so, as the hint count beside the names does.
            if rules.history.count>plies,let last=rules.records.last{let mover:NetworkSide=last.color=="b" ? .black:.white;announce(NetworkWording.move(last,players:players)+(game.assistedPlies.last==rules.history.count ? ". "+NetworkWording.usedHint(mover,players:players):""))}
        }
        // A12: joining or watching a game with assistance announces its terms once, as the line under the names shows them.
        if first,part != .host,let terms=NetworkWording.terms(game.assistance,players:players){announce(terms)}
        if pending != nil,gameRevision != pendingRevision{clearPending()}
        if let offer=openOffer,offer != previousOffer,offer.by != learnerSide{announce("\(players.name(offer.by)) offers a draw")}
        if let offer=previousOffer,openOffer==nil,outcome==nil,!moved,offer.by==learnerSide{announce("\(opponentName) declined the draw")}
        if let outcome,previousOutcome==nil{
            announce(NetworkWording.result(outcome,players:players))
            // Protocol 1.3: a finished mini-game is reviewed by the proof search, whatever ended it.
            if let game=rules as? NetworkMiniGame,let kind=game.ruleset?.kind,let moves=try? game.networkMoves(),!moves.isEmpty {miniReview.start(session:sessionNumber,kind:kind,moves:moves.map{MiniGameMove(from:String($0.prefix(2)),to:String($0.suffix(2)))})}
        }
    }
    private var learnerSeat:Seat? {
        switch part {case .host?,.guest?:return learnerSide.map{.player(side:$0.rawValue)};case .spectator?:return .spectator;case nil:return nil}
    }
    /// Sets a published value only when it changes, so a clock-only status redraws nothing.
    private func update<Value:Equatable>(_ key:ReferenceWritableKeyPath<NetworkGameController,Value>,_ value:Value){if self[keyPath:key] != value{self[keyPath:key]=value}}
    /// After every event: participation, the crash file, the clock announcements and the title follow the state.
    private func settle(){updateParticipation();saveCrashFile();watchClocks();updateTitle();onSettle()}
    private func updateTitle(){
        guard part != nil || !detached else{return}
        let next:String
        switch part {
        case nil:next=Self.lobbyTitle
        case .host?:next=whiteName != nil && blackName != nil ? "\(players.name(.white)) vs \(players.name(.black))":gameName
        case .guest?,.spectator?:next=record != nil ? "\(players.name(.white)) vs \(players.name(.black))":part == .guest ? "Joining \(gameName)":"Watching \(gameName)"
        }
        update(\.title,next)
    }

    // MARK: Participation and the crash file (D8, D9)
    private var wantedParticipation:NetworkParticipation.Role? {
        // A seat that can still be tried again is still held (D8 ends participation only once it is given up).
        guard let part,runner != nil || canTryAgain,!leaving,outcome==nil else{return nil}
        switch part {
        case .host:return hostPhase == .reserved || hostPhase == .running || hostPhase == .disconnected ? .player:nil
        case .guest:return seated ? .player:nil
        case .spectator:return watching ? .spectator:nil
        }
    }
    /// The learner's own side's level, from terms the game verified (A3): the host's own settings, or the snapshot a
    /// guest checked against what it accepted. Nothing before the record arrives.
    private var wantedAssistance:NetworkAssistanceLevel {
        guard wantedParticipation == .player,let record,let learnerSide else{return .off}
        return record.assistance.level(learnerSide)
    }
    private func updateParticipation(){
        let wanted=wantedParticipation,level=wantedAssistance
        guard wanted != participating || level != participatingAssistance else{return}
        participating=wanted;participatingAssistance=level
        if let wanted{participation?.begin(wanted,assistance:level)}else{participation?.end();services?.crashFile?.clear();savedRecord=nil}
    }

    // MARK: Assistance (assistance plan A1, A7)
    /// The game's terms, as verified (A3); `off` before any record.
    public var assistance:NetworkAssistance {record?.assistance ?? .off}
    /// The shown game starts from a declared start (mini-games plan D7), as verified.
    public var declaredStart:Bool {record?.startFEN != nil}
    /// A hint was shown to the learner on their move: the move they make this turn is flagged `assisted` (A7).
    public func hintShown(){guard yourTurn,let gameRevision else{return};assistedTurn=gameRevision}
    /// Whether a hint was shown during the learner's current turn.
    public var assistedThisTurn:Bool {assistedTurn != nil && assistedTurn==gameRevision && yourTurn}
    /// Writes the record whenever it changes while participating; a clock reading alone changes nothing the notice or
    /// Review use, so it is not rewritten every second.
    private func saveCrashFile(){
        guard participating != nil,let crashFile=services?.crashFile,let record else{return}
        var key=record;key.clocks=nil
        guard key != savedRecord else{return}
        let part:NetworkCrashFile.Part=self.part == .spectator ? .spectator:learnerSide == .black ? .black:.white
        do{try crashFile.save(NetworkCrashFile.Entry(game:record,part:part));savedRecord=key}
        catch{NativeLog.storage.error("The network game could not be kept for the crash notice: \(String(describing:error),privacy:.public)")}
    }

    // MARK: Clocks (D6, D10)
    /// Clocks count down locally between the host's readings while the game is live; they hold still while the
    /// connection is regained, as the host's are paused for a guest away.
    private var countingDown:Bool {link == .live && outcome==nil}
    /// Both clocks as they read at `now`; nil for an untimed game.
    public func clocks(at now:NetworkInstant)->NetworkClocks? {
        guard var clocks=clockSync?.clocks,let at=clockSync?.at else{return nil}
        if countingDown,let side=clocks.active,now>at {
            let (seconds,attoseconds)=(now-at).components,elapsed=Int(seconds)*1000+Int(attoseconds/1_000_000_000_000_000)
            let left=max(0,clocks.remaining(side)-elapsed);if side == .white{clocks.white=left}else{clocks.black=left}
        }
        return clocks
    }
    /// The clocks now, on the services' clock.
    public var currentClocks:NetworkClocks? {services.flatMap{clocks(at:$0.scheduler.now)}}
    /// Announces a running clock as it passes 60, 30 and 10 seconds (D10), then waits for the next one. Each event
    /// re-arms it; a crossing seen late, between two readings, is still announced once. A threshold is announced again
    /// only after an increment has taken the clock clearly back above it, so a host reading a few milliseconds above
    /// the local countdown cannot repeat one.
    ///
    /// One alarm waits at a time, and a reading that points it at the same threshold at nearly the same moment keeps
    /// it: the readings come every second, and replacing the alarm each time would leave a cancelled dispatch for
    /// every reading until its deadline.
    /// Alarms scheduled so far: tests check that readings which change nothing reuse the one waiting.
    private(set) var clockAlarmsScheduled=0
    private func watchClocks(){
        guard let services,countingDown,let clocks=clocks(at:services.scheduler.now),let side=clocks.active else{return dropClockAlarm()}
        let left=clocks.remaining(side)
        if let announced=clockAnnounced[side],left>announced+Self.clockSlack{clockAnnounced[side]=nil}
        if let before=clockSeen[side],let crossed=NetworkWording.clockThresholds.filter({left<=$0 && $0<before && $0<(clockAnnounced[side] ?? .max)}).min(){
            clockAnnounced[side]=crossed;announce(NetworkWording.clock(side,threshold:crossed,players:players))
        }
        clockSeen[side]=left
        guard let next=NetworkWording.nextClockThreshold(below:left) else{return dropClockAlarm()}
        let due=services.scheduler.now + .milliseconds(left-next)
        if clockAlarm != nil,let target=clockAlarmTarget,target.side==side,target.threshold==next,max(target.due-due,due-target.due) <= .milliseconds(Self.clockSlack) {return}
        dropClockAlarm()
        let watch=clockWatch;clockAlarmTarget=(side,next,due);clockAlarmsScheduled+=1
        clockAlarm=Self.alarm(services.scheduler,at:due,services.delivery){[weak self] in guard let self,self.clockWatch==watch else{return};self.clockAlarm=nil;self.clockAlarmTarget=nil;self.watchClocks()}
    }
    /// Cancels the waiting clock alarm, if any, on the scheduler's queue; a late fire is ignored by its number.
    private func dropClockAlarm(){
        clockWatch+=1;clockAlarmTarget=nil
        if let alarm=clockAlarm,let scheduler=services?.scheduler{clockAlarm=nil;scheduler.enqueue{alarm.cancel()}}
    }

    // MARK: Commands
    private func command(host action:NetworkHostAction,client:(NetworkClientRunner)->Void){
        switch runner {case .host(let runner,_)?:runner.perform(action);case .client(let runner)?:client(runner);case nil:break}
    }
    private var playing:Bool {inputOpen && learnerSide != nil}
    public var canOfferDraw:Bool {playing && openOffer==nil}
    /// The other player's offer is open: Accept or Decline.
    public var canAnswerDraw:Bool {playing && openOffer != nil && openOffer?.by != learnerSide}
    /// Threefold repetition or fifty moves, on the learner's move; the host checks again on its own rules (D5).
    public var canClaimDraw:Bool {yourTurn && rules.drawClaimable}
    /// The host may resign while the guest is away; a guest while connected.
    public var canResign:Bool {
        guard runner != nil,!leaving,outcome==nil else{return false}
        switch part {case .host?:return hostPhase == .running || hostPhase == .disconnected;case .guest?:return link == .live && seated;default:return false}
    }
    /// Leaving now counts as a resignation (D9): ask first.
    public var leavingResigns:Bool {
        guard runner != nil,!leaving,outcome==nil else{return false}
        switch part {case .host?:return hostPhase == .running || hostPhase == .disconnected;case .guest?:return seated;default:return false}
    }
    /// A runner is still open: quitting waits for it to leave.
    public var sessionOpen:Bool {runner != nil}
    /// Changes with every session, so a confirmation answers only for the session it was asked about.
    public var sessionID:Int {sessionNumber}
    /// The game this Mac hosts, while its listeners are open.
    public var hostedGameID:NetworkGameID? {if case .host(_,let configuration)?=runner {return configuration.gameID};return nil}
    public func offerDraw(){guard canOfferDraw else{return};command(host:.offerDraw){$0.offerDraw()}}
    public func answerDraw(accept:Bool){guard canAnswerDraw else{return};command(host:.answerDraw(accept:accept)){$0.answerDraw(accept:accept)}}
    public func claimDraw(){guard yourTurn else{return};command(host:.claimDraw){$0.claimDraw()}}
    public func resign(){guard canResign else{return};command(host:.resign){$0.resign()}}
    public func claimWin(){guard part == .host,holdExpired else{return};command(host:.claimWin){_ in}}
    public func keepWaiting(){guard part == .host,holdExpired else{return};command(host:.keepWaiting){_ in}}
    /// Leaves the session: a seated player resigns, the host's `ended` goes out before its listeners close (R3-2), a
    /// spectator just leaves; then back to the lobby, and `done` runs. Participation and the crash file end at once.
    /// The Mac is going to sleep (D9). A host's listeners would vanish under its guests, and its clock would charge the
    /// whole sleep to the side to move, so the game stops now as interrupted, with no result. A guest or spectator
    /// closes its connection at once, so the host pauses the clocks now, and resumes on waking while the seat is held.
    public func systemWillSleep(){
        guard !leaving,outcome==nil else{return}
        switch runner {
        case .host(let runner,_)?:sleptWhileHosting=true;runner.interrupt("This Mac went to sleep.")
        case .client(let runner)?:runner.suspend()
        case nil:break
        }
    }
    /// The Mac woke (D9): a guest or spectator that closed its connection for the sleep reconnects now.
    public func systemDidWake(){if case .client(let runner)?=runner {runner.wake()}}
    private var sleptWhileHosting=false
    public func leave(then done:@escaping @MainActor ()->Void={}){
        guard part != nil else{return done()}
        guard let runner else{endSession();return done()}
        leaveCompletions.append(done)
        guard !leaving else{return}
        let resigning=leavingResigns
        leaving=true;clearPending();settle()
        switch runner {case .host(let runner,_):runner.perform(.leave);case .client(let runner):runner.leave(resigning:resigning)}
    }
    private func finishLeaving(){let done=leaveCompletions;leaveCompletions=[];endSession();done.forEach{$0()}}
    /// The app is closing (a quit already waited for any leave it confirmed): leave without waiting, stop browsing,
    /// and keep no crash file, since this is a clean exit (D9).
    public func shutdown(){
        if runner != nil,!leaving{leave()}
        shown=false;refreshBrowsing();services?.crashFile?.clear()
    }

    // MARK: Review (D9)
    /// A game that ended, or stopped without a result, can be reviewed once it has a move.
    /// A mini-game is reviewed only once it has a result (protocol 1.3): an interrupted one has no review.
    public var canReview:Bool {record != nil && !rules.history.isEmpty && (outcome != nil || link == .stopped && ruleset==nil)}
    /// Review this game, for a mini-game: its proof-search review, now or as soon as it is ready.
    public func showMiniReview(){guard canReview,ruleset != nil else{return};miniReview.showSheet()}
    /// The review record: D9's headers over the game's moves; `*` for an interrupted game.
    /// Opening Review gives up Try Again, so engine help returns only once the seat is let go (D8).
    public func reviewRecord()->String? {
        guard canReview,let record,ruleset==nil else{return nil}
        if retryable{retryable=false;objectWillChange.send();settle()}
        // The moves as this Mac's rules replayed the record (A11), not the record's text.
        do{return NetworkGameRecord.reviewPGN(record,moves:try rules.moveHistory().map(\.san),on:services?.today() ?? Date())}
        catch{NativeLog.lifecycle.error("A network game could not be prepared for Review: \(String(describing:error),privacy:.public)");return nil}
    }
    /// What the pane says under the players.
    public var statusText:String? {
        guard let part else{return nil}
        if let stopMessage{return stopMessage}
        if let outcome{return NetworkWording.result(outcome,players:players)}
        switch link {
        case .connecting:return part == .spectator ? "Connecting to \(gameName)…":"Joining \(gameName)…"
        case .denied:return "Waiting for Local Network access…"
        case .waiting:return "Waiting for someone to join. Share the play code."
        case .reconnecting:return "Reconnecting to \(gameName)…"
        case .away:return holdExpired ? "\(opponentName) has been away for a while. Claim the win, or keep waiting.":"\(opponentName) is away. Their seat is held for 2 minutes."
        case .stopped:return leaving ? "Leaving…":nil
        case .live:
            if leaving{return "Leaving…"}
            if hostPhase == .reserved{return "\(opponentName) is joining…"}
            let turn:NetworkSide=rules.turn=="b" ? .black:.white
            return turn==learnerSide ? "Your move.":"\(players.name(turn))'s move."
        }
    }
}
