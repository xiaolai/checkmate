import CheckmateDomain
import Foundation
/// The Bonjour service type of each build kind (D12). `build.sh` declares the same one in `NSBonjourServices`, which
/// is where the app reads it back.
public enum NetworkServiceType {
    public static let release="_checkmate._tcp",development="_checkmate-dev._tcp",automation="_checkmate-auto._tcp"
    public static let all:Set<String>=[release,development,automation]
}
/// One service instance as found. Unauthenticated: the key covers only the game ID, so a forged game ID or role only
/// yields the wrong key and the handshake fails closed, while the name and the advertised terms are display only. The
/// terms are checked inside TLS afterwards (A3): by the host against what the guest accepted, and by the guest against
/// every snapshot.
public struct NetworkServiceRecord:Equatable {
    public let name:String,txt:[String:String],endpoint:NetworkEndpoint
    public init(name:String,txt:[String:String],endpoint:NetworkEndpoint){self.name=name;self.txt=txt;self.endpoint=endpoint}
    /// What a hosted game publishes for one listener.
    public static func published(_ configuration:NetworkHostingConfiguration,_ role:NetworkListenerRole,at endpoint:NetworkEndpoint)->NetworkServiceRecord {
        NetworkServiceRecord(name:configuration.serviceName(for:role),txt:configuration.txt(role),endpoint:endpoint)
    }
    var gameID:NetworkGameID? {txt["game"].flatMap(NetworkGameID.init)}
    var role:NetworkListenerRole? {txt["role"].flatMap(NetworkListenerRole.init(rawValue:))}
    /// The terms as advertised (A3): nil when absent (a 1.0 host, whose games have none) or unreadable.
    var assistance:NetworkAssistance? {txt["assist"].flatMap(NetworkAssistance.init(txt:))}
}
/// A game as the joiner sees it: its two listeners' records paired by the game ID in their TXT, never by name (D3). The
/// joiner then types only the code; the game ID, and so the key's salt and identity, comes from the record chosen.
public struct NetworkDiscoveredGame:Equatable {
    public let gameID:NetworkGameID
    public private(set) var seat:NetworkServiceRecord?,watch:NetworkServiceRecord?
    /// The seat instance's name, or the watch instance's without its suffix while only that one is seen.
    public var name:String {
        if let seat {return seat.name}
        guard let name=watch?.name else{return ""}
        return name.hasSuffix(NetworkHostingConfiguration.watchSuffix) ? String(name.dropLast(NetworkHostingConfiguration.watchSuffix.count)):name
    }
    /// "Ana's game · K7QD": two hosts with the same name are told apart by the game ID's last four symbols.
    public var displayName:String {"\(name) · \(gameID.displaySuffix)"}
    /// The terms the list shows (A3), from the seat record, else the watch record; `off` when neither states any, as
    /// a 1.0 host's never do. Untrusted: the join sheet asks the person to accept these, and the host and the guest
    /// then check the real terms inside TLS.
    public var assistance:NetworkAssistance {seat?.assistance ?? watch?.assistance ?? .off}
    public func record(_ role:NetworkListenerRole)->NetworkServiceRecord? {role == .seat ? seat:watch}
    public func key(_ role:NetworkListenerRole,code:NetworkCode)->NetworkAccessKey {NetworkAccessKey(gameID:gameID,role:role,code:code)}
    /// Games in order of first appearance. A record without a valid `game` and `role` is ignored. The first record for
    /// a game and role wins: one service seen on two interfaces is reported twice, and either reaches it. Pairing is
    /// linear in the records, and at most `maximumGames` games are listed: advertisements are unauthenticated, so a
    /// flood of them costs bounded work on every update.
    public static let maximumGames=256
    public static func pair(_ records:[NetworkServiceRecord])->[NetworkDiscoveredGame] {
        var games:[NetworkDiscoveredGame]=[],positions:[NetworkGameID:Int]=[:]
        for record in records {
            guard let gameID=record.gameID,let role=record.role else{continue}
            var index=positions[gameID]
            if index==nil {guard games.count<maximumGames else{continue};games.append(NetworkDiscoveredGame(gameID:gameID));index=games.count-1;positions[gameID]=index}
            switch role {
            case .seat where games[index!].seat==nil:games[index!].seat=record
            case .watch where games[index!].watch==nil:games[index!].watch=record
            default:break
            }
        }
        return games
    }
    private init(gameID:NetworkGameID){self.gameID=gameID}
}
public enum NetworkDiscoveryUpdate:Equatable {
    /// Every game currently seen; an update replaces the last.
    case games([NetworkDiscoveredGame])
    /// Local-network access denied (TN3179's browser signal, DNS error -65570). Browsing waits and goes on by itself
    /// once access is granted.
    case denied
    case failed(String)
}
/// Finds hosted games. Bonjour in the app (CheckmateMacPlatform); an injected source in tests and the loopback gate
/// (D12). Updates arrive on the scheduler. Browsing stops as soon as a game is chosen (D1): the chooser calls `stop`.
public protocol NetworkDiscovery:AnyObject {
    func start(_ updates:@escaping (NetworkDiscoveryUpdate)->Void)
    func stop()
}
/// An injected discovery source (D12): fixed records, no Bonjour. `publish` replaces them while browsing.
public final class NetworkFixedDiscovery:NetworkDiscovery {
    private let scheduler:any NetworkScheduler
    private var records:[NetworkServiceRecord],updates:((NetworkDiscoveryUpdate)->Void)?
    /// Each start begins a new session; an update queued for an earlier one is dropped, not handed to the new one.
    private var session=0
    public init(records:[NetworkServiceRecord]=[],scheduler:any NetworkScheduler){self.records=records;self.scheduler=scheduler}
    public func start(_ updates:@escaping (NetworkDiscoveryUpdate)->Void){session+=1;self.updates=updates;deliver()}
    public func stop(){session+=1;updates=nil}
    public func publish(_ records:[NetworkServiceRecord]){self.records=records;deliver()}
    private func deliver(){
        let games=NetworkDiscoveredGame.pair(records),current=session
        scheduler.enqueue{[weak self] in guard let self,self.session==current else{return};self.updates?(.games(games))}
    }
}
