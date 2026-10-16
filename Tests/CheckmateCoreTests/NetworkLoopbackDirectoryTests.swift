import XCTest
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
        let configuration=NetworkHostingConfiguration(gameID:.random(using:.system),seatCode:.random(using:.system),watchCode:.random(using:.system),serviceName:"Ana's game")
        shared.publish(configuration,[.seat:NWNetworkTransport.loopbackEndpoint(port:50_001),.watch:NWNetworkTransport.loopbackEndpoint(port:50_002)])
        let discovery=shared.discovery(interval:.milliseconds(20))
        let lock=NSLock();var updates:[[NetworkDiscoveredGame]]=[]
        let found=expectation(description:"found"),gone=expectation(description:"gone")
        scheduler.enqueue{discovery.start{update in
            guard case .games(let games)=update else{return}
            lock.lock();updates.append(games);let count=updates.count;lock.unlock()
            if count==1{found.fulfill()}else if count==2{gone.fulfill()}
        }}
        wait(for:[found],timeout:5)
        lock.lock();let first=updates[0];lock.unlock()
        XCTAssertEqual(first.count,1);XCTAssertEqual(first.first?.gameID,configuration.gameID);XCTAssertEqual(first.first?.name,"Ana's game")
        XCTAssertEqual(first.first?.record(.seat)?.endpoint,NWNetworkTransport.loopbackEndpoint(port:50_001));XCTAssertEqual(first.first?.record(.watch)?.endpoint,NWNetworkTransport.loopbackEndpoint(port:50_002))
        shared.withdraw(configuration.gameID)
        wait(for:[gone],timeout:5)
        lock.lock();XCTAssertEqual(updates.last,[],"a withdrawn game is gone");XCTAssertEqual(updates.count,2,"an unchanged directory reports nothing new");lock.unlock()
        let stopped=expectation(description:"stopped");scheduler.enqueue{discovery.stop();stopped.fulfill()};wait(for:[stopped],timeout:5)
    }
    /// Only loopback listeners are published: anything else writes nothing, so no instance is sent off the Mac.
    func testAListenerOffLoopbackIsNotPublished(){
        let shared=NetworkLoopbackDirectory(directory:directory,scheduler:NetworkQueueScheduler())
        let configuration=NetworkHostingConfiguration(gameID:.random(using:.system),seatCode:.random(using:.system),watchCode:nil,serviceName:"Ana's game")
        shared.publish(configuration,[.seat:NetworkEndpoint("memory-1-seat",description:"memory-1-seat")])
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.appendingPathComponent(configuration.gameID.text+".json").path))
    }
}
