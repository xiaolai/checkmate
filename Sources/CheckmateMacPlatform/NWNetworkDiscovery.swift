import CheckmateApplication
import CheckmateDomain
import Foundation
@preconcurrency import Network
/// Bonjour discovery (D1, D3, D11): an `NWBrowser` for the build's service type with TXT records, no peer-to-peer
/// Wi-Fi. Results are paired by the game ID in their TXT, never by name. TN3179's browser denial signal, DNS error
/// -65570 while waiting, is reported as `denied`; browsing then waits and goes on by itself once access is granted.
/// Every call must be made on the scheduler's queue, and every update arrives there.
public final class NWNetworkDiscovery:NetworkDiscovery {
    public let serviceType:String
    private let scheduler:NetworkQueueScheduler
    private var browser:NWBrowser?
    public init(serviceType:String,scheduler:NetworkQueueScheduler){self.serviceType=serviceType;self.scheduler=scheduler}
    public func start(_ updates:@escaping (NetworkDiscoveryUpdate)->Void){
        scheduler.assertOnQueue()
        stop()
        let parameters=NWParameters();parameters.includePeerToPeer=false
        let browser=NWBrowser(for:.bonjourWithTXTRecord(type:serviceType,domain:nil),using:parameters)
        browser.stateUpdateHandler={[weak self,weak browser] state in
            guard let self,let browser,self.browser===browser else{return}
            switch state {
            case .waiting(let error):if case .dns(let code)=error,code == -65570 {updates(.denied)}
            case .failed(let error):updates(.failed("\(error)"))
            // Ready again, after a denial say: the current results go out even if unchanged, so the lobby clears its
            // permission help (D11's recovery) without waiting for a game to come or go.
            case .ready:updates(.games(NetworkDiscoveredGame.pair(Self.records(browser.browseResults))))
            default:break
            }
        }
        browser.browseResultsChangedHandler={[weak self,weak browser] results,_ in
            guard let self,let browser,self.browser===browser else{return}
            updates(.games(NetworkDiscoveredGame.pair(Self.records(results))))
        }
        self.browser=browser
        browser.start(queue:scheduler.queue)
    }
    public func stop(){
        scheduler.assertOnQueue()
        browser?.stateUpdateHandler=nil;browser?.browseResultsChangedHandler=nil;browser?.cancel();browser=nil
    }
    /// Results arrive as a set; sorting by name, then endpoint, keeps pairing's "first record wins" the same every time.
    static func records(_ results:Set<NWBrowser.Result>)->[NetworkServiceRecord] {
        results.compactMap{result->NetworkServiceRecord? in
            guard case .service(let name,_,_,_)=result.endpoint,case .bonjour(let txt)=result.metadata else{return nil}
            return NetworkServiceRecord(name:name,txt:txt.dictionary,endpoint:NetworkEndpoint(result.endpoint,description:"\(result.endpoint)"))
        }.sorted{($0.name,$0.endpoint.description)<($1.name,$1.endpoint.description)}
    }
}
