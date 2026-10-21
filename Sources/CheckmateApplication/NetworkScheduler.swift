import CheckmateAssets
import CheckmateDomain
import Foundation
/// The one serial queue a network game runs on, and its clock (LAN-play plan D6). Every event — a message, a send
/// completing, a timer, a command from the interface — runs here, stamped with the moment the queue starts it. A runner
/// and the transport it uses share one scheduler, so neither needs a lock.
public protocol NetworkScheduler:AnyObject {
    /// Monotonic time since an origin fixed when the scheduler was made.
    var now:NetworkInstant {get}
    /// Runs `work` on the queue after everything already enqueued.
    func enqueue(_ work:@escaping ()->Void)
    /// Runs `work` on the queue once `deadline` has passed, unless it is cancelled first. It never runs early.
    func schedule(at deadline:NetworkInstant,_ work:@escaping ()->Void)->NetworkScheduledWork
}
/// Work waiting for its deadline. Cancel it on the scheduler's queue; once cancelled it never runs.
public final class NetworkScheduledWork {
    public private(set) var cancelled=false
    public init(){}
    public func cancel(){cancelled=true}
}
/// The app's scheduler: a dispatch queue and `ContinuousClock`, which keeps counting while the Mac sleeps, so a deadline
/// that passed during sleep has passed on wake.
public final class NetworkQueueScheduler:NetworkScheduler {
    public let queue:DispatchQueue
    private let clock=ContinuousClock(),origin:ContinuousClock.Instant
    public init(queue:DispatchQueue=DispatchQueue(label:"checkmate.network")){self.queue=queue;origin=clock.now}
    public var now:NetworkInstant {NetworkInstant(origin.duration(to:clock.now))}
    public func enqueue(_ work:@escaping ()->Void){queue.async(execute:work)}
    public func schedule(at deadline:NetworkInstant,_ work:@escaping ()->Void)->NetworkScheduledWork {
        let token=NetworkScheduledWork();arm(token,deadline,work);return token
    }
    /// Dispatch's clock stops during sleep, so a fire is never early in continuous time, only late; a fire a hair early
    /// from rounding re-arms for the rest rather than run before its deadline.
    private func arm(_ token:NetworkScheduledWork,_ deadline:NetworkInstant,_ work:@escaping ()->Void){
        let (seconds,attoseconds)=max(.zero,deadline-now).components
        queue.asyncAfter(deadline:.now() + .nanoseconds(Int(seconds)*1_000_000_000+Int(attoseconds/1_000_000_000))){[self] in
            guard !token.cancelled else{return}
            if now<deadline {arm(token,deadline,work)}else{work()}
        }
    }
    /// Traps when called off the queue: the transport and runners are confined to it.
    public func assertOnQueue(){dispatchPrecondition(condition:.onQueue(queue))}
}
/// A scheduler whose time moves only when a test moves it, for the in-memory transport: every run is the same run.
/// The test is the queue: `run` performs enqueued work and due timers until nothing is left.
public final class NetworkManualScheduler:NetworkScheduler {
    public private(set) var now:NetworkInstant
    private var ready:[()->Void]=[]
    private var timed:[(deadline:NetworkInstant,order:Int,token:NetworkScheduledWork,work:()->Void)]=[]
    private var order=0
    public init(at start:NetworkInstant = .origin){now=start}
    public func enqueue(_ work:@escaping ()->Void){ready.append(work)}
    public func schedule(at deadline:NetworkInstant,_ work:@escaping ()->Void)->NetworkScheduledWork {
        let token=NetworkScheduledWork();order+=1;timed.append((deadline,order,token,work));return token
    }
    /// Pending work: enqueued closures and timers not cancelled.
    public var pending:Int {ready.count+timed.filter{!$0.token.cancelled}.count}
    /// Runs enqueued work, and timers due by now, until none is left. A loop that never settles traps.
    public func run(){
        var steps=0
        while true {
            steps+=1;precondition(steps<1_000_000,"Network work never settles.")
            if !ready.isEmpty {ready.removeFirst()();continue}
            guard let next=nextTimer(by:now) else{return}
            timed.remove(at:next).work()
        }
    }
    /// Moves time to `target`, running each timer at its own deadline, in deadline order, with the work it causes.
    public func advance(to target:NetworkInstant){
        run()
        while let next=nextTimer(by:target) {
            let item=timed.remove(at:next);now=max(now,item.deadline);item.work();run()
        }
        now=max(now,target);run()
    }
    public func advance(by duration:Duration){advance(to:now+duration)}
    /// Runs until `condition` holds, moving time in `step`s; false if it never held by `limit`.
    @discardableResult public func advance(until condition:()->Bool,step:Duration = .milliseconds(10),limit:Duration = .seconds(600))->Bool {
        precondition(step > .zero,"A step must move time forward.")
        let end=now+limit;run()
        while !condition() {guard now<end else{return false};advance(to:min(now+step,end))}
        return true
    }
    private func nextTimer(by limit:NetworkInstant)->Int? {
        timed.removeAll{$0.token.cancelled}
        return timed.indices.filter{timed[$0].deadline<=limit}.min{(timed[$0].deadline,timed[$0].order)<(timed[$1].deadline,timed[$1].order)}
    }
}
