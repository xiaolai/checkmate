import CheckmateDomain
import CheckmateRules
import CheckmateSupport
import Foundation
import Darwin
/// One serialized process, with protocol barriers. Cancellation kills the process;
/// uncertain output is never reused by a later search.
final class UCIWorker:@unchecked Sendable {
    let executable:URL
    private let lifecycle=NSLock(),serial=NSLock()
    private var process:Process?,input:FileHandle?,output:FileHandle?,pending=UCILines(),generation=0
    /// The process whose launch and handshake are in progress, and the startup it belongs to. Its startup watchdog stops
    /// it even when a later search has reserved a newer generation meanwhile, which would make `cancel(expected:)` a
    /// no-op and leave the handshake, and every search waiting behind it, blocked. The watchdog names its own startup,
    /// so one that fires late, after a newer startup began, can never stop that newer process.
    private var starting:Process?,startups=0,startupToken:Int?
    /// The startup in progress, read under the same lock its writers hold (startup and watchdog threads).
    var startup:Int? {lifecycle.lock();defer{lifecycle.unlock()};return startupToken}
    /// The `prepare` call whose startup is in progress, and those cancelled before they took the worker, so cancelling
    /// a preparation ends only its own startup (`cancelPreparation`).
    private var preparing:(ticket:Int,epoch:Int)?,preparingStartup:Int?,cancelledPreparations=Set<Int>(),tickets=0
    /// Test seam: runs between a process's launch and its registration, where a cancellation once left it untracked.
    var afterLaunch:(()->Void)?
    private(set) var capabilities=EngineCapabilities()
    /// The option values the running process holds. Each is sent only when it changes: Stockfish rebuilds its threads
    /// and hash table on every Threads or Hash command, even an unchanged one. A new process starts with none.
    private var applied:[String:String]=[:]
    init(executable:URL,startupAllowance:TimeInterval=10){self.executable=executable;self.startupAllowance=startupAllowance}
    deinit{cancel()}
    func reserve()->Int {lifecycle.lock();defer{lifecycle.unlock()};generation+=1;return generation}
    private func isCurrent(_ epoch:Int)->Bool {lifecycle.lock();defer{lifecycle.unlock()};return epoch==generation}
    func cancel(expected:Int?=nil){lifecycle.lock();if let expected=expected,expected != generation{lifecycle.unlock();return};generation+=1;let process=process;self.process=nil;lifecycle.unlock();if let process{Self.stop(process)}}
    /// Stops a process: SIGTERM, then SIGKILL if it is still running 0.3 s later, so one that ignores SIGTERM ends too.
    static func stop(_ process:Process){guard process.isRunning else{return};process.terminate();DispatchQueue.global().asyncAfter(deadline:.now()+0.3){if process.isRunning{kill(process.processIdentifier,SIGKILL)}}}
    func metadata()->EngineCapabilities {serial.lock();defer{serial.unlock()};return capabilities}
    /// A ticket for one `prepare` call, so `cancelPreparation` can name it before or while it runs.
    func preparationTicket()->Int {lifecycle.lock();defer{lifecycle.unlock()};tickets+=1;return tickets}
    func prepare(ticket:Int?=nil)throws -> EngineCapabilities {
        serial.lock();defer{serial.unlock()};lifecycle.lock()
        if let ticket,cancelledPreparations.contains(ticket){lifecycle.unlock();throw CheckmateError.cancelled}
        let epoch=generation;if let ticket{preparing=(ticket,epoch)};lifecycle.unlock()
        defer{lifecycle.lock();if preparing?.ticket==ticket{preparing=nil;preparingStartup=nil};lifecycle.unlock()}
        try startWithinAllowance(epoch:epoch);return capabilities
    }
    /// Ends preparation `ticket`: one that has not yet begun its startup never begins it; one starting stops its own
    /// startup, unless a search has reserved the worker since, which would only have to start the engine again.
    func cancelPreparation(_ ticket:Int){
        lifecycle.lock();cancelledPreparations.insert(ticket)
        guard let current=preparing,current.ticket==ticket,let token=preparingStartup,generation==current.epoch else{lifecycle.unlock();return}
        lifecycle.unlock();abandonStartup(token,epoch:current.epoch)
    }
    /// Forgets preparation `ticket` once its call has returned, so a cancellation recorded for it is not kept for good.
    func forgetPreparation(_ ticket:Int){lifecycle.lock();cancelledPreparations.remove(ticket);lifecycle.unlock()}
    /// Launch and the UCI handshake (a cold start loads the network) get their own allowance, so a slow start
    /// is never charged to a search's deadline. Ten seconds in the app; tests shorten it.
    private let startupAllowance:TimeInterval
    private func startWithinAllowance(epoch:Int)throws {
        lifecycle.lock()
        // A preparation cancelled before its startup began does not begin it.
        if let current=preparing,cancelledPreparations.contains(current.ticket){lifecycle.unlock();throw CheckmateError.cancelled}
        startups+=1;let token=startups;startupToken=token;if preparing != nil{preparingStartup=token};lifecycle.unlock()
        let timeout=DispatchWorkItem{[weak self] in self?.abandonStartup(token,epoch:epoch)};DispatchQueue.global().asyncAfter(deadline:.now()+startupAllowance,execute:timeout);defer{timeout.cancel()}
        do{try start(epoch:epoch)}catch{abandonStartup(token,epoch:epoch);throw error}
        lifecycle.lock();if startupToken==token{startupToken=nil};lifecycle.unlock()
    }
    /// Ends startup `token`, in one step under the lock, if it is still the startup in progress: it stops the process
    /// being started, and ends `epoch` if nothing newer has been reserved. A late or repeated call is a no-op.
    func abandonStartup(_ token:Int,epoch:Int){
        lifecycle.lock();guard startupToken==token else{lifecycle.unlock();return}
        startupToken=nil;let process=starting;starting=nil;if self.process===process{self.process=nil};if generation==epoch{generation+=1};lifecycle.unlock()
        if let process{Self.stop(process)}
    }
    private func send(_ command:String)throws {guard let input=input else{throw CheckmateError.unavailable("Engine pipe unavailable.")};try input.write(contentsOf:Data((command+"\n").utf8))}
    private func line()throws -> String {while true{if let line=pending.next(){return line};guard let data=output?.availableData,!data.isEmpty else{throw CheckmateError.unavailable("Engine stopped responding.")};try pending.append(data)}}
    private func barrier(_ target:String)throws {while true{let text=try line();capabilities.ingest(text);if text==target{return}}}
    private func start(epoch:Int)throws {
        guard isCurrent(epoch) else{throw CheckmateError.cancelled}
        lifecycle.lock();let alive=process?.isRunning==true;lifecycle.unlock();if alive{return}
        pending=UCILines();capabilities=EngineCapabilities();applied=[:];let process=Process(),inPipe=Pipe(),outPipe=Pipe()
        process.executableURL=executable;process.currentDirectoryURL=executable.deletingLastPathComponent();process.environment=ProcessInfo.processInfo.environment.merging(EngineRuntimePolicy.environment){_,policy in policy};process.standardInput=inPipe;process.standardOutput=outPipe;process.standardError=FileHandle.nullDevice;signal(SIGPIPE,SIG_IGN)
        try process.run();afterLaunch?();lifecycle.lock();guard generation==epoch else{lifecycle.unlock();Self.stop(process);throw CheckmateError.cancelled};self.process=process;starting=process;lifecycle.unlock();input=inPipe.fileHandleForWriting;output=outPipe.fileHandleForReading
        try send("uci");try barrier("uciok");try send("isready");try barrier("readyok")
        lifecycle.lock();if starting===process{starting=nil};lifecycle.unlock()
    }
    /// `limit` is a time in milliseconds or a node count (A5); the calibration nodes of a silent run replace either.
    func search(startFEN:String,moves:[String],finalFEN:String,profile:OpponentProfile,limit:EngineSearchLimit,multiPv:Int,searchMoves:[String],epoch:Int,resources:EngineResources?=nil)throws -> EngineAnalysis {
        serial.lock();defer{serial.unlock()}
        guard isCurrent(epoch) else{throw CheckmateError.cancelled}
        // The position command is one line: a line break in it would end the command early and stop Stockfish.
        guard !(startFEN+finalFEN).contains(where:\.isNewline) else{throw CheckmateError.invalid("Invalid position.")}
        try startWithinAllowance(epoch:epoch)
        // A node search has no time of its own; ten seconds is far beyond any node count the app asks for.
        let budget:Int,go:String
        switch limit {case .movetime(let milliseconds):budget=milliseconds;go="go movetime \(milliseconds)";case .nodes(let nodes):budget=0;go="go nodes \(nodes)"}
        let timeout=DispatchWorkItem{[weak self] in self?.cancel(expected:epoch)};DispatchQueue.global().asyncAfter(deadline:.now()+(budget>0 ? Double(budget)/1000+2:10),execute:timeout);defer{timeout.cancel()}
        do {
            guard isCurrent(epoch) else{throw CheckmateError.cancelled};try send("ucinewgame")
            var options=AnalysisPolicy.options;for (key,value) in profile.options{options[key]=value};for (key,value) in resources?.options ?? [:]{options[key]=value};options["MultiPV"]=String(multiPv)
            if profile.mode=="elo"{guard let range=capabilities.eloRange else{throw CheckmateError.unavailable("Engine Elo mode unavailable.")};options["UCI_Elo"]=String(max(range.lowerBound,min(range.upperBound,profile.value)))}
            if profile.mode=="skill"{options["Skill Level"]=String(max(capabilities.skillRange.lowerBound,min(capabilities.skillRange.upperBound,profile.value)))}
            for (key,value) in options.sorted(by:{$0.key<$1.key}) where capabilities.options.contains(key) && applied[key] != value{try send("setoption name \(key) value \(value)");applied[key]=value}
            try send("isready");try barrier("readyok")
            try send("position fen \(startFEN)"+(moves.isEmpty ? "":" moves "+moves.joined(separator:" ")))
            let calibrationNodes=NativePolicy.silent ? Int(ProcessInfo.processInfo.environment["CHECKMATE_CALIBRATION_NODES"] ?? ""):nil
            let command=calibrationNodes.map{"go nodes \(max(100,min(100000,$0)))"} ?? go
            try send(command+(searchMoves.isEmpty ? "":" searchmoves "+searchMoves.joined(separator:" ")))
            var snapshots:[Int:[Int:AnalysisLine]]=[:],best:String?,finished=false
            let sign=finalFEN.split(separator:" ")[1]=="w" ? 1:-1
            while !finished {
                let text=try line(),fields=text.split(separator:" ").map(String.init)
                if fields.first=="bestmove"{guard fields.count>1 else{throw CheckmateError.unavailable("Invalid bestmove.")};best=ChessRules.validUCI(fields[1]) ? fields[1]:nil;guard best != nil || ["(none)","0000"].contains(fields[1]) else{throw CheckmateError.unavailable("Invalid bestmove.")};finished=true;continue}
                guard fields.first=="info",let score=fields.firstIndex(of:"score"),score+2<fields.count,let value=Int(fields[score+2]),let pv=fields.firstIndex(of:"pv") else{continue}
                func number(_ key:String,_ fallback:Int=0)->Int {guard let i=fields.firstIndex(of:key),i+1<fields.count else{return fallback};return Int(fields[i+1]) ?? fallback}
                let depth=number("depth"),rank=number("multipv",1),rawBound=fields.contains("lowerbound") ? "lower":fields.contains("upperbound") ? "upper":nil,bound=sign==1 ? rawBound:rawBound.map{$0=="lower" ? "upper":"lower"}
                var line=AnalysisLine(depth:depth,multiPv:rank,score:AnalysisScore(kind:fields[score+1],value:sign*value,bound:bound),pv:Array(fields.dropFirst(pv+1).prefix(32)),san:[])
                line.nodes=number("nodes");line.timeMs=number("time")
                if let w=fields.firstIndex(of:"wdl"),w+3<fields.count{let numbers=fields[(w+1)...(w+3)].compactMap(Int.init);line.wdl=sign==1 ? numbers:numbers.reversed()}
                snapshots[depth,default:[:]][rank]=line
                if snapshots.count>8,let min=snapshots.keys.min(){snapshots.removeValue(forKey:min)}
            }
            lifecycle.lock();let valid=epoch==generation;lifecycle.unlock();guard valid else{throw CheckmateError.cancelled}
            let complete=snapshots.keys.filter{snapshots[$0]?.count==multiPv}.max() ?? snapshots.keys.max()
            let lines=complete.map{snapshots[$0]!.values.sorted{$0.multiPv<$1.multiPv}} ?? []
            try send("isready");try barrier("readyok")
            return EngineAnalysis(bestMove:best,budgetMs:budget,lines:lines)
        }catch{cancel(expected:epoch);throw error}
    }
}
/// The engine's output as lines, however its reads split them: bytes are kept until a line ends, so a line that arrives
/// in pieces is returned whole. Bounded, so an engine that never ends a line cannot grow it without limit.
struct UCILines {
    static let limit=2*1024*1024
    /// Bytes, not text, so a character split across two reads is decoded whole.
    private var bytes=Data()
    /// The next whole line, trimmed, or nil until one has arrived.
    mutating func next()->String? {guard let end=bytes.firstIndex(of:0x0A) else{return nil};let line=String(decoding:bytes[..<end],as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines);bytes.removeSubrange(...end);return line}
    mutating func append(_ data:Data)throws {bytes.append(data);guard bytes.count<Self.limit else{throw CheckmateError.unavailable("Engine output limit exceeded.")}}
}
