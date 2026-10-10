import Foundation
import Darwin
/// One serialized process, with protocol barriers. Cancellation kills the process;
/// uncertain output is never reused by a later search.
final class UCIWorker:@unchecked Sendable {
    let executable:URL
    private let lifecycle=NSLock(),serial=NSLock()
    private var process:Process?,input:FileHandle?,output:FileHandle?,pending="",generation=0
    private(set) var capabilities=EngineCapabilities()
    init(executable:URL){self.executable=executable}
    deinit{cancel()}
    func reserve()->Int {lifecycle.lock();defer{lifecycle.unlock()};generation+=1;return generation}
    private func isCurrent(_ epoch:Int)->Bool {lifecycle.lock();defer{lifecycle.unlock()};return epoch==generation}
    func cancel(expected:Int?=nil){lifecycle.lock();if let expected=expected,expected != generation{lifecycle.unlock();return};generation+=1;let process=process;self.process=nil;lifecycle.unlock();if process?.isRunning==true{process?.terminate();DispatchQueue.global().asyncAfter(deadline:.now()+0.3){if let process=process,process.isRunning{kill(process.processIdentifier,SIGKILL)}}}}
    func metadata()->EngineCapabilities {serial.lock();defer{serial.unlock()};return capabilities}
    func prepare()throws -> EngineCapabilities {
        serial.lock();defer{serial.unlock()};lifecycle.lock();let epoch=generation;lifecycle.unlock()
        let timeout=DispatchWorkItem{[weak self] in self?.cancel(expected:epoch)};DispatchQueue.global().asyncAfter(deadline:.now()+3,execute:timeout);defer{timeout.cancel()}
        do{try start(epoch:epoch);return capabilities}catch{cancel(expected:epoch);throw error}
    }
    private func send(_ command:String)throws {guard let input=input else{throw CheckmateError.unavailable("Engine pipe unavailable.")};try input.write(contentsOf:Data((command+"\n").utf8))}
    private func line()throws -> String {while true{if let end=pending.firstIndex(of:"\n"){let line=String(pending[..<end]).trimmingCharacters(in:.whitespacesAndNewlines);pending.removeSubrange(...end);return line};guard let data=output?.availableData,!data.isEmpty else{throw CheckmateError.unavailable("Engine stopped responding.")};pending+=String(decoding:data,as:UTF8.self);guard pending.count<2*1024*1024 else{throw CheckmateError.unavailable("Engine output limit exceeded.")}}}
    private func barrier(_ target:String)throws {while true{let text=try line();capabilities.ingest(text);if text==target{return}}}
    private func start(epoch:Int)throws {
        guard isCurrent(epoch) else{throw CheckmateError.cancelled}
        lifecycle.lock();let alive=process?.isRunning==true;lifecycle.unlock();if alive{return}
        pending="";capabilities=EngineCapabilities();let process=Process(),inPipe=Pipe(),outPipe=Pipe()
        process.executableURL=executable;process.currentDirectoryURL=executable.deletingLastPathComponent();process.environment=ProcessInfo.processInfo.environment.merging(EngineRuntimePolicy.environment){_,policy in policy};process.standardInput=inPipe;process.standardOutput=outPipe;process.standardError=FileHandle.nullDevice;signal(SIGPIPE,SIG_IGN)
        try process.run();lifecycle.lock();guard generation==epoch else{lifecycle.unlock();process.terminate();throw CheckmateError.cancelled};self.process=process;lifecycle.unlock();input=inPipe.fileHandleForWriting;output=outPipe.fileHandleForReading
        try send("uci");try barrier("uciok");try send("isready");try barrier("readyok")
    }
    func search(startFEN:String,moves:[String],finalFEN:String,profile:OpponentProfile,budget:Int,multiPv:Int,searchMoves:[String],epoch:Int)throws -> EngineAnalysis {
        serial.lock();defer{serial.unlock()}
        guard isCurrent(epoch) else{throw CheckmateError.cancelled}
        let timeout=DispatchWorkItem{[weak self] in self?.cancel(expected:epoch)};DispatchQueue.global().asyncAfter(deadline:.now()+Double(budget)/1000+2,execute:timeout);defer{timeout.cancel()}
        do {
            try start(epoch:epoch);guard isCurrent(epoch) else{throw CheckmateError.cancelled};try send("ucinewgame")
            var options=AnalysisPolicy.options;for (key,value) in profile.options{options[key]=value};options["MultiPV"]=String(multiPv)
            if profile.mode=="elo"{guard let range=capabilities.eloRange else{throw CheckmateError.unavailable("Engine Elo mode unavailable.")};options["UCI_Elo"]=String(max(range.lowerBound,min(range.upperBound,profile.value)))}
            if profile.mode=="skill"{options["Skill Level"]=String(max(capabilities.skillRange.lowerBound,min(capabilities.skillRange.upperBound,profile.value)))}
            for (key,value) in options.sorted(by:{$0.key<$1.key}) where capabilities.options.contains(key){try send("setoption name \(key) value \(value)")}
            try send("isready");try barrier("readyok")
            try send("position fen \(startFEN)"+(moves.isEmpty ? "":" moves "+moves.joined(separator:" ")))
            let calibrationNodes=NativePolicy.silent ? Int(ProcessInfo.processInfo.environment["CHECKMATE_CALIBRATION_NODES"] ?? ""):nil
            let command=calibrationNodes.map{"go nodes \(max(100,min(100000,$0)))"} ?? "go movetime \(budget)"
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
