import CheckmateDomain
import Foundation
/// What a network session needs from the app (LAN-play plan D13). NativeModel builds it over Network.framework and
/// Bonjour, or over loopback listeners and an injected discovery source for the loopback gate (D12); tests build it over
/// `NetworkMemoryTransport` and a manual scheduler with `.immediate` delivery.
public struct NetworkServices {
    public var transport:any NetworkTransport
    /// Bonjour in the app; fixed records in tests and the loopback gate (D12).
    public var discovery:any NetworkDiscovery
    /// The one queue every runner, the transport and the discovery share (D6).
    public var scheduler:any NetworkScheduler
    /// How events leave that queue for the main actor.
    public var delivery:NetworkDelivery
    public var rules:NetworkRulesFactory
    public var hashing:NetworkHashing
    public var random:NetworkRandom
    /// Made once per launch: credentials are bound to it, so a restarted host never resumes a game (D4).
    public var runEpoch:NetworkID
    /// Sent in `hello`.
    public var appVersion:String
    /// The game in progress, kept for the next launch's crash notice (D9); nil keeps nothing.
    public var crashFile:NetworkCrashFile?
    /// The day a review record is dated.
    public var today:()->Date
    /// Told on the main actor when a hosted game's listeners are ready, and when they close. The loopback gate
    /// publishes them to the other instances' discovery (D12); the app's Bonjour listeners advertise themselves.
    public var listenersReady:(NetworkHostingConfiguration,[NetworkListenerRole:NetworkEndpoint])->Void
    public var listenersClosed:(NetworkGameID)->Void
    public init(transport:any NetworkTransport,discovery:any NetworkDiscovery,scheduler:any NetworkScheduler,delivery:NetworkDelivery,rules:NetworkRulesFactory,hashing:NetworkHashing,random:NetworkRandom = .system,runEpoch:NetworkID?=nil,appVersion:String,crashFile:NetworkCrashFile?=nil,today:@escaping ()->Date={Date()},listenersReady:@escaping (NetworkHostingConfiguration,[NetworkListenerRole:NetworkEndpoint])->Void={_,_ in},listenersClosed:@escaping (NetworkGameID)->Void={_ in}){
        self.transport=transport;self.discovery=discovery;self.scheduler=scheduler;self.delivery=delivery;self.rules=rules;self.hashing=hashing;self.random=random
        self.runEpoch=runEpoch ?? .random(using:random);self.appVersion=appVersion;self.crashFile=crashFile;self.today=today;self.listenersReady=listenersReady;self.listenersClosed=listenersClosed
    }
}
/// How an event leaves the network queue for the main actor, in the order it was made.
public struct NetworkDelivery {
    private let hop:(@escaping @MainActor ()->Void)->Void
    public init(_ hop:@escaping (@escaping @MainActor ()->Void)->Void){self.hop=hop}
    public func callAsFunction(_ work:@escaping @MainActor ()->Void){hop(work)}
    /// The app: the main queue, first in, first out.
    public static var mainQueue:NetworkDelivery {NetworkDelivery{work in DispatchQueue.main.async{MainActor.assumeIsolated{work()}}}}
    /// A scheduler that already runs on the main thread, as a test's manual scheduler does: at once.
    public static var immediate:NetworkDelivery {NetworkDelivery{work in MainActor.assumeIsolated{work()}}}
}
/// Discovery for a build that cannot browse: one with no Bonjour service type declared (D11, D12). It says so on
/// start rather than finding nothing silently.
public final class NetworkUnavailableDiscovery:NetworkDiscovery {
    private let scheduler:any NetworkScheduler,reason:String
    private var updates:((NetworkDiscoveryUpdate)->Void)?
    public init(scheduler:any NetworkScheduler,reason:String){self.scheduler=scheduler;self.reason=reason}
    public func start(_ updates:@escaping (NetworkDiscoveryUpdate)->Void){
        self.updates=updates
        let reason=reason
        scheduler.enqueue{[weak self] in self?.updates?(.failed(reason))}
    }
    public func stop(){updates=nil}
}
/// The host sheet (D10): the side the host takes, the time control, and whether spectators may watch. The name is the
/// controller's `playerName`, shared with joining and watching.
public struct NetworkHostForm:Equatable {
    public var side:NetworkSideChoice = .white
    public var timeControl:NetworkTimeControl = .untimed
    public var allowSpectators=true
    /// The terms the host offers (assistance plan A2); fixed once the game is hosted.
    public var assistance:NetworkAssistance = .off
    /// The game-library position the game starts from (mini-games plan D7), or nil for the standard start. Offered
    /// only with `NetworkPolicy.positionsEnabled`; hosting ignores it otherwise.
    public var start:NetworkLibraryStart?
    /// The simplified mini-game to play instead of chess (protocol 1.3), or nil for chess. Offered only with
    /// `NetworkPolicy.miniGamesEnabled`, and only the competitive kinds (`NetworkRuleset.supported`); hosting ignores it
    /// otherwise. A mini-game has its own start and no assistance, so those choices are set aside while one is chosen.
    public var miniGame:MiniGameKind?
    public init(){}
}
