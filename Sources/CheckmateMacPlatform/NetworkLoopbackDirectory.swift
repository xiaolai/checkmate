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
///
/// A record lives only as long as the process that published it, as a Bonjour registration does: mDNSResponder drops
/// one when its process dies. An instance stopped by a signal never reaches `withdraw`, so each record names its
/// publisher's process by number and start time, and a record whose process is gone, or whose number now belongs to a
/// later process, is never listed and is deleted when read.
public final class NetworkLoopbackDirectory {
    public let directory:URL
    private let scheduler:NetworkQueueScheduler
    private let process:Int32,started:(Int32)->Int64?
    /// `process` and `started` default to this process and the kernel's record of when a process started; tests stand
    /// in a process that has ended or been replaced.
    public init(directory:URL,scheduler:NetworkQueueScheduler,process:Int32=ProcessInfo.processInfo.processIdentifier,started:@escaping (Int32)->Int64?=NetworkLoopbackDirectory.startTime){self.directory=directory;self.scheduler=scheduler;self.process=process;self.started=started}
    /// When a running process started, in microseconds since 1970; nil once it is gone. A process number can be given to
    /// a later process, the start time cannot.
    public static func startTime(_ pid:Int32)->Int64? {
        guard pid>0 else{return nil}
        var info=kinfo_proc(),size=MemoryLayout<kinfo_proc>.stride,name:[Int32]=[CTL_KERN,KERN_PROC,KERN_PROC_PID,pid]
        guard sysctl(&name,UInt32(name.count),&info,&size,nil,0)==0,size>0,info.kp_proc.p_pid==pid else{return nil}
        return Int64(info.kp_proc.p_starttime.tv_sec)*1_000_000+Int64(info.kp_proc.p_starttime.tv_usec)
    }
    /// The largest record file read: a game's two records are well under 1 KiB.
    static let maximumRecordBytes=65_536
    /// The most record files read in one look: one per hosted game, and a gate hosts a handful.
    static let maximumRecordFiles=64
    /// `assist` is the TXT value of the same name (assistance plan A3); absent in a record written before it existed.
    /// `pid` and `started` are the publishing process.
    private struct Entry:Codable {let name:String,game:String,role:String,port:UInt16;var assist:String?;let pid:Int32,started:Int64}
    private func file(_ gameID:NetworkGameID)->URL {directory.appendingPathComponent(gameID.text+".json")}
    /// Writes a hosted game's records, replacing any earlier ones for it.
    public func publish(_ configuration:NetworkHostingConfiguration,_ endpoints:[NetworkListenerRole:NetworkEndpoint]){
        let entries=endpoints.compactMap{role,endpoint->Entry? in
            guard case .hostPort(let host,let port)?=endpoint.value as? NWEndpoint,Self.loopback(host) else{return nil}
            return Entry(name:configuration.serviceName(for:role),game:configuration.gameID.text,role:role.rawValue,port:port.rawValue,assist:configuration.assistance.txt,pid:process,started:started(process) ?? 0)
        }.sorted{$0.role<$1.role}
        do{
            guard entries.count==endpoints.count else{throw CheckmateError.invalid("A listener is not on loopback.")}
            guard entries.allSatisfy({$0.started>0}) else{throw CheckmateError.unavailable("This process's start time could not be read.")}
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try JSONEncoder().encode(entries).write(to:file(configuration.gameID),options:.atomic)
        }catch{NativeLog.lifecycle.error("The loopback game record could not be published: \(String(describing:error),privacy:.public)")}
    }
    public func withdraw(_ gameID:NetworkGameID){try? FileManager.default.removeItem(at:file(gameID))}
    /// Discovery rewrites every record to 127.0.0.1, so only a listener on exactly that address may be published: one
    /// on ::1 or another loopback address would be advertised where it does not listen.
    static func loopback(_ host:NWEndpoint.Host)->Bool {
        guard case .ipv4(let address)=host else{return false}
        return address==IPv4Address.loopback
    }
    /// A record file's bytes: a regular file, not followed through a link, and small. Anything else in the shared
    /// directory, such as a FIFO that would block the read or a huge file, is skipped. The checks are made on the one
    /// descriptor that is read, opened without following a link or waiting on a FIFO, so a file swapped or grown after
    /// it was listed cannot get past them, and the read stops one byte past the limit whatever the file's size.
    static func contents(_ url:URL)->Data? {
        let descriptor=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard descriptor>=0 else{return nil}
        defer{close(descriptor)}
        var status=stat()
        guard fstat(descriptor,&status)==0,status.st_mode & S_IFMT==S_IFREG,status.st_size<=maximumRecordBytes else{return nil}
        var data=Data(count:maximumRecordBytes+1),total=0
        while total<data.count {
            let count=data.withUnsafeMutableBytes{read(descriptor,$0.baseAddress!+total,$0.count-total)}
            if count<0,errno==EINTR {continue}
            guard count>=0 else{return nil}
            if count==0 {break}
            total+=count
        }
        guard total<=maximumRecordBytes else{return nil}
        return data.prefix(total)
    }
    /// Every record in the directory now, in file-name order so pairing's "first record wins" is the same every time.
    func records()->[NetworkServiceRecord] {
        let files=((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []).filter{$0.pathExtension=="json"}.sorted{$0.lastPathComponent<$1.lastPathComponent}.prefix(Self.maximumRecordFiles)
        return files.flatMap{url->[NetworkServiceRecord] in
            guard let data=Self.contents(url),let entries=try? JSONDecoder().decode([Entry].self,from:data) else{return []}
            guard entries.allSatisfy({started($0.pid)==$0.started}) else{try? FileManager.default.removeItem(at:url);return []}
            return entries.map{entry in var txt=["game":entry.game,"role":entry.role];txt["assist"]=entry.assist;return NetworkServiceRecord(name:entry.name,txt:txt,endpoint:NWNetworkTransport.loopbackEndpoint(port:entry.port))}
        }
    }
    /// A discovery that reads the directory now and every `interval` while browsing. Calls and updates are on the
    /// scheduler's queue, as with Bonjour.
    public func discovery(interval:Duration = .milliseconds(500))->any NetworkDiscovery {Browser(directory:self,scheduler:scheduler,interval:interval)}
    /// Runs after every look at the directory, on the scheduler's queue: tests count looks that found nothing new.
    var looked:(()->Void)?
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
            directory.looked?()
            _ = scheduler.schedule(at:scheduler.now+interval){[weak self] in self?.poll(current)}
        }
    }
}
