import CheckmateApplication
import CheckmateDomain
import CheckmateSupport
import Foundation
@preconcurrency import Network
import OSLog
/// Discovery for the loopback gate (LAN-play plan D12): several automation instances on one Mac, listeners bound to
/// 127.0.0.1 and no Bonjour. A hosting instance writes its listeners' records into a shared directory, one file per
/// game; every instance's discovery reads them back. A record here is as untrusted as a Bonjour one: a wrong one only
/// yields the wrong key, so the handshake fails closed.
public final class NetworkLoopbackDirectory {
    public let directory:URL
    private let scheduler:NetworkQueueScheduler
    public init(directory:URL,scheduler:NetworkQueueScheduler){self.directory=directory;self.scheduler=scheduler}
    private struct Entry:Codable {let name:String,game:String,role:String,port:UInt16}
    private func file(_ gameID:NetworkGameID)->URL {directory.appendingPathComponent(gameID.text+".json")}
    /// Writes a hosted game's records, replacing any earlier ones for it.
    public func publish(_ configuration:NetworkHostingConfiguration,_ endpoints:[NetworkListenerRole:NetworkEndpoint]){
        let entries=endpoints.compactMap{role,endpoint->Entry? in
            guard case .hostPort(_,let port)?=endpoint.value as? NWEndpoint else{return nil}
            return Entry(name:configuration.serviceName(for:role),game:configuration.gameID.text,role:role.rawValue,port:port.rawValue)
        }.sorted{$0.role<$1.role}
        do{
            guard entries.count==endpoints.count else{throw CheckmateError.invalid("A listener is not on loopback.")}
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try JSONEncoder().encode(entries).write(to:file(configuration.gameID),options:.atomic)
        }catch{NativeLog.lifecycle.error("The loopback game record could not be published: \(String(describing:error),privacy:.public)")}
    }
    public func withdraw(_ gameID:NetworkGameID){try? FileManager.default.removeItem(at:file(gameID))}
    /// Every record in the directory now, in file-name order so pairing's "first record wins" is the same every time.
    func records()->[NetworkServiceRecord] {
        let files=((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []).filter{$0.pathExtension=="json"}.sorted{$0.lastPathComponent<$1.lastPathComponent}
        return files.flatMap{url->[NetworkServiceRecord] in
            guard let data=try? Data(contentsOf:url),let entries=try? JSONDecoder().decode([Entry].self,from:data) else{return []}
            return entries.map{NetworkServiceRecord(name:$0.name,txt:["game":$0.game,"role":$0.role],endpoint:NWNetworkTransport.loopbackEndpoint(port:$0.port))}
        }
    }
    /// A discovery that reads the directory now and every `interval` while browsing. Calls and updates are on the
    /// scheduler's queue, as with Bonjour.
    public func discovery(interval:Duration = .milliseconds(500))->any NetworkDiscovery {Browser(directory:self,scheduler:scheduler,interval:interval)}
    private final class Browser:NetworkDiscovery {
        private let directory:NetworkLoopbackDirectory,scheduler:NetworkQueueScheduler,interval:Duration
        private var updates:((NetworkDiscoveryUpdate)->Void)?,generation=0,last:[NetworkDiscoveredGame]?
        init(directory:NetworkLoopbackDirectory,scheduler:NetworkQueueScheduler,interval:Duration){self.directory=directory;self.scheduler=scheduler;self.interval=interval}
        func start(_ updates:@escaping (NetworkDiscoveryUpdate)->Void){
            scheduler.assertOnQueue()
            self.updates=updates;generation+=1;last=nil;poll(generation)
        }
        func stop(){scheduler.assertOnQueue();updates=nil;generation+=1}
        private func poll(_ current:Int){
            guard current==generation,let updates else{return}
            let games=NetworkDiscoveredGame.pair(directory.records())
            if games != last {last=games;updates(.games(games))}
            _ = scheduler.schedule(at:scheduler.now+interval){[weak self] in self?.poll(current)}
        }
    }
}
