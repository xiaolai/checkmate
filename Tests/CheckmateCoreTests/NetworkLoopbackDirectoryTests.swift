import XCTest
@preconcurrency import Network
@testable import CheckmateApplication
@testable import CheckmateDomain
@testable import CheckmateMacPlatform

/// The loopback gate's discovery (LAN-play plan D12): a hosting instance publishes its listeners into a shared
/// directory and every instance's discovery reads them back; nothing touches Bonjour or the network.
final class NetworkLoopbackDirectoryTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent("checkmate-loopback-\(UUID().uuidString)",isDirectory:true)}
    override func tearDown(){try? FileManager.default.removeItem(at:directory)}

    func testPublishedListenersAreFoundAndWithdrawn()throws {
        let scheduler=NetworkQueueScheduler(),shared=NetworkLoopbackDirectory(directory:directory,scheduler:scheduler)
        let configuration=NetworkHostingConfiguration(gameID:.random(using:.system),seatCode:.random(using:.system),watchCode:.random(using:.system),serviceName:"Ana's game",assistance:NetworkAssistance(white:.insight,black:.guided))
        shared.publish(configuration,[.seat:NWNetworkTransport.loopbackEndpoint(port:50_001),.watch:NWNetworkTransport.loopbackEndpoint(port:50_002)])
        let discovery=shared.discovery(interval:.milliseconds(20))
        let lock=NSLock();var updates:[[NetworkDiscoveredGame]]=[],looks=0
        let found=expectation(description:"found"),gone=expectation(description:"gone"),unchanged=expectation(description:"five looks after the first find")
        shared.looked={lock.lock();if !updates.isEmpty {looks+=1};let count=looks;lock.unlock();if count==5 {unchanged.fulfill()}}
        scheduler.enqueue{discovery.start{update in
            guard case .games(let games)=update else{return}
            lock.lock();updates.append(games);let count=updates.count;lock.unlock()
            if count==1{found.fulfill()}else if count==2{gone.fulfill()}
        }}
        wait(for:[found],timeout:5)
        // Five looks at the unchanged directory, each one confirmed, report nothing new.
        wait(for:[unchanged],timeout:5)
        lock.lock();let snapshot=updates;lock.unlock()
        XCTAssertEqual(snapshot.count,1,"unchanged looks report nothing")
        let first=try XCTUnwrap(snapshot.first)
        XCTAssertEqual(first.count,1);XCTAssertEqual(first.first?.gameID,configuration.gameID);XCTAssertEqual(first.first?.name,"Ana's game")
        XCTAssertEqual(first.first?.assistance,NetworkAssistance(white:.insight,black:.guided),"the terms are published for the list (assistance plan A3)")
        // Each listener's record carries the terms itself: either alone lists the game with them.
        for role in [NetworkListenerRole.seat,.watch] {
            XCTAssertEqual(first.first?.record(role)?.txt["assist"],"ig","the \(role) record's own terms")
            let alone=NetworkDiscoveredGame.pair(shared.records().filter{$0.txt["role"]==role.rawValue})
            XCTAssertEqual(alone.first?.assistance,NetworkAssistance(white:.insight,black:.guided),"the \(role) record alone")
        }
        XCTAssertEqual(first.first?.record(.seat)?.endpoint,NWNetworkTransport.loopbackEndpoint(port:50_001));XCTAssertEqual(first.first?.record(.watch)?.endpoint,NWNetworkTransport.loopbackEndpoint(port:50_002))
        shared.withdraw(configuration.gameID)
        wait(for:[gone],timeout:5)
        lock.lock();XCTAssertEqual(updates.last,[],"a withdrawn game is gone");XCTAssertEqual(updates.count,2,"only the two changes were reported");lock.unlock()
        let stopped=expectation(description:"stopped");scheduler.enqueue{discovery.stop();stopped.fulfill()};wait(for:[stopped],timeout:5)
    }
    /// A record outlives no publisher, as with Bonjour: an instance stopped by a signal never withdraws its game, so a
    /// record whose process has ended is not listed, and reading it deletes it.
    func testARecordWhoseProcessEndedIsNotListed(){
        var ended:Set<Int32>=[]
        let scheduler=NetworkQueueScheduler(),shared=NetworkLoopbackDirectory(directory:directory,scheduler:scheduler,process:4242,started:{ended.contains($0) ? nil:1_000})
        let configuration=NetworkHostingConfiguration(gameID:.random(using:.system),seatCode:.random(using:.system),watchCode:nil,serviceName:"Ana's game")
        shared.publish(configuration,[.seat:NWNetworkTransport.loopbackEndpoint(port:50_003)])
        let file=directory.appendingPathComponent(configuration.gameID.text+".json")
        XCTAssertEqual(shared.records().count,1,"a live publisher's game is listed")
        ended.insert(4242)
        XCTAssertEqual(shared.records().count,0,"a game whose publisher ended is not listed")
        XCTAssertFalse(FileManager.default.fileExists(atPath:file.path),"reading it deletes the stale record")
    }
    /// A process number the kernel has given to a later process does not keep an ended publisher's game listed.
    func testARecordWhoseProcessNumberWasReusedIsNotListed(){
        var start:Int64=1_000
        let shared=NetworkLoopbackDirectory(directory:directory,scheduler:NetworkQueueScheduler(),process:4242,started:{_ in start})
        let configuration=NetworkHostingConfiguration(gameID:.random(using:.system),seatCode:.random(using:.system),watchCode:nil,serviceName:"Ana's game")
        shared.publish(configuration,[.seat:NWNetworkTransport.loopbackEndpoint(port:50_004)])
        XCTAssertEqual(shared.records().count,1)
        start=2_000
        XCTAssertEqual(shared.records().count,0,"the same number started later is another process")
    }
    func testTheProcessProbe()throws {
        let own=try XCTUnwrap(NetworkLoopbackDirectory.startTime(ProcessInfo.processInfo.processIdentifier))
        XCTAssertGreaterThan(own,0);XCTAssertEqual(NetworkLoopbackDirectory.startTime(ProcessInfo.processInfo.processIdentifier),own,"a process's start time is stable")
        XCTAssertNil(NetworkLoopbackDirectory.startTime(0));XCTAssertNil(NetworkLoopbackDirectory.startTime(-1))
        let child=Process();child.executableURL=URL(fileURLWithPath:"/usr/bin/true");try child.run();child.waitUntilExit()
        XCTAssertNil(NetworkLoopbackDirectory.startTime(child.processIdentifier),"a reaped child is gone")
    }
    /// Only loopback listeners are published: anything else writes nothing, so no instance is sent off the Mac.
    func testAListenerOffLoopbackIsNotPublished(){
        let shared=NetworkLoopbackDirectory(directory:directory,scheduler:NetworkQueueScheduler())
        let configuration=NetworkHostingConfiguration(gameID:.random(using:.system),seatCode:.random(using:.system),watchCode:nil,serviceName:"Ana's game")
        shared.publish(configuration,[.seat:NetworkEndpoint("memory-1-seat",description:"memory-1-seat")])
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent(configuration.gameID.text+".json").path))
        // A host-and-port listener on another address, which discovery would otherwise rewrite to this Mac.
        let away=NWEndpoint.hostPort(host:"203.0.113.5",port:50_005)
        shared.publish(configuration,[.seat:NetworkEndpoint(away,description:"\(away)")])
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent(configuration.gameID.text+".json").path))
        // Discovery rewrites every record to 127.0.0.1, so only exactly that address is published.
        XCTAssertTrue(NetworkLoopbackDirectory.loopback("127.0.0.1"))
        for other in ["::1","127.0.0.2","localhost","203.0.113.5"] as [NWEndpoint.Host] {XCTAssertFalse(NetworkLoopbackDirectory.loopback(other),"\(other)")}
        shared.publish(configuration,[.seat:NetworkEndpoint(NWEndpoint.hostPort(host:"::1",port:50_005),description:"[::1]:50005")])
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent(configuration.gameID.text+".json").path),"a listener on ::1 is not advertised at 127.0.0.1")
    }
    /// Only small regular files are read: a FIFO would block discovery, a huge file would fill memory.
    func testOnlySmallRegularRecordFilesAreRead()throws {
        let shared=NetworkLoopbackDirectory(directory:directory,scheduler:NetworkQueueScheduler())
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        XCTAssertEqual(mkfifo(directory.appendingPathComponent("fifo.json").path,0o600),0)
        // A valid record of a live process, padded past the limit: listed if it were read.
        let pid=ProcessInfo.processInfo.processIdentifier,start=try XCTUnwrap(NetworkLoopbackDirectory.startTime(pid))
        let big=#"[{"name":"Big","game":"\#(NetworkGameID.random(using:.system).text)","role":"seat","port":50007,"pid":\#(pid),"started":\#(start)}]"#
        try Data((big+String(repeating:" ",count:NetworkLoopbackDirectory.maximumRecordBytes)).utf8).write(to:directory.appendingPathComponent("huge.json"))
        let configuration=NetworkHostingConfiguration(gameID:.random(using:.system),seatCode:.random(using:.system),watchCode:nil,serviceName:"Ana's game")
        shared.publish(configuration,[.seat:NWNetworkTransport.loopbackEndpoint(port:50_006)])
        // Read off the test's thread with a deadline: a regression that blocks on the FIFO fails here rather than
        // hanging the whole run.
        XCTAssertEqual(try withinDeadline{shared.records().compactMap{$0.txt["game"]}},[configuration.gameID.text],"the FIFO and the huge file are skipped, without blocking")
    }
    /// The checks hold for the file actually read: a link is not followed, and a FIFO is not waited on.
    func testARecordIsReadThroughOneDescriptorWithoutFollowingLinks()throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let target=directory.appendingPathComponent("target.txt"),link=directory.appendingPathComponent("link.json"),fifo=directory.appendingPathComponent("fifo.json")
        try Data("[]".utf8).write(to:target);try FileManager.default.createSymbolicLink(at:link,withDestinationURL:target)
        XCTAssertEqual(NetworkLoopbackDirectory.contents(target),Data("[]".utf8))
        XCTAssertNil(NetworkLoopbackDirectory.contents(link),"a link is not followed")
        XCTAssertEqual(mkfifo(fifo.path,0o600),0)
        XCTAssertNil(try withinDeadline{NetworkLoopbackDirectory.contents(fifo)},"a FIFO is not read, and not waited on")
        try Data(repeating:0x20,count:NetworkLoopbackDirectory.maximumRecordBytes+1).write(to:target)
        XCTAssertNil(NetworkLoopbackDirectory.contents(target),"one byte over the limit is not read")
    }
    private struct Blocked:Error,CustomStringConvertible {var description:String {"the read blocked for 5 s"}}
    /// Runs `work` on another thread and fails, rather than waiting forever, if it does not finish within 5 s.
    private func withinDeadline<T>(_ work:@escaping ()->T)throws -> T {
        let done=DispatchSemaphore(value:0),lock=NSLock();var result:T?
        Thread.detachNewThread{let value=work();lock.lock();result=value;lock.unlock();done.signal()}
        guard done.wait(timeout:.now()+5) == .success else{throw Blocked()}
        lock.lock();defer{lock.unlock()};return result!
    }
}
