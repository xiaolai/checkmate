import XCTest
import Foundation
@testable import CheckmateDomain

/// Finished mini-games for WI-018's spike and usefulness gate. The calibration harness (WI-016) does not exist yet, so
/// this small deterministic generator stands in for its corpus: the opponent's profiles against each other and against
/// a random player, with fixed seeds and the opponent's time limit off.
enum MiniGameCorpus {
    static let pairings=[("standard","random"),("random","standard"),("challenging","beginner"),("beginner","challenging"),("standard","challenging")]
    static func game(_ kind:MiniGameKind,white:String,black:String,seed:UInt64,maximumPlies:Int=200)->MiniGameState {
        var game=MiniGameState(kind:kind,computer:true),random=seed &* 0x9E3779B97F4A7C15 | 1;game.opponentSeed=String(seed,radix:16)
        for ply in 0..<maximumPlies {
            guard !game.isFinished else{break}
            let profile=game.turn=="w" ? white:black,move:MiniGameMove?
            if profile=="random" {
                let moves=MiniGameRules.moves(board:game.board,kind:kind,side:game.turn)
                random=random &* 6364136223846793005 &+ 1442695040888963407;move=moves.isEmpty ? nil:moves[Int((random >> 33) % UInt64(moves.count))]
            } else {move=MiniGameOpponent.choose(in:game,profile:profile,seed:seed &+ UInt64(ply),timeLimited:false)}
            guard let move,game.play(move) else{break}
        }
        return game
    }
    static func games(seeds:ClosedRange<UInt64>)->[(kind:MiniGameKind,white:String,black:String,seed:UInt64,game:MiniGameState)] {
        MiniGameKind.allCases.filter{!$0.solo}.flatMap{kind in pairings.flatMap{pair in seeds.map{seed in (kind,pair.0,pair.1,seed,game(kind,white:pair.0,black:pair.1,seed:seed))}}}
    }
}
/// WI-018's spike: run with `CHECKMATE_MINI_PROOF_SPIKE=<output.json>` on the test host (release build for the CPU
/// budget). It measures nodes, memory, CPU time, cancellation latency and proven-fact coverage for every competitive
/// kind at the pinned budgets, and checks the usefulness gate: at least half the decisive games yield a proven fact.
final class MiniGameProofSpikeTests:XCTestCase {
    static func cpuSeconds()->Double {Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID))/1e9}
    static func footprint()->UInt64 {
        var info=task_vm_info_data_t(),count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<natural_t>.size)
        let status=withUnsafeMutablePointer(to:&info){$0.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)}}
        return status==KERN_SUCCESS ? info.phys_footprint:0
    }
    func testSpikeMeasurementsAndUsefulnessGate()throws {
        guard let path=ProcessInfo.processInfo.environment["CHECKMATE_MINI_PROOF_SPIKE"] else{throw XCTSkip("Set CHECKMATE_MINI_PROOF_SPIKE=<output.json> to run the WI-018 spike")}
        let seeds=UInt64(ProcessInfo.processInfo.environment["CHECKMATE_MINI_PROOF_SEEDS"] ?? "3") ?? 3
        let generated=Date(),corpus=MiniGameCorpus.games(seeds:1...seeds),generation=Date().timeIntervalSince(generated)
        var games:[[String:Any]]=[],perKind:[String:[String:Int]]=[:]
        for entry in corpus {
            let game=entry.game,baseline=Self.footprint();var peak=baseline,polls=0
            let start=Self.cpuSeconds(),wall=Date()
            let review=MiniGameReview.run(game,cpuSeconds:Self.cpuSeconds,stop:{polls+=1;if polls%16==0{peak=max(peak,Self.footprint())};return false})
            let cpu=Self.cpuSeconds()-start,elapsed=Date().timeIntervalSince(wall)
            let decisive=game.winner != nil,exact=review.answers.values.filter{$0.result != .unknown}.count
            let row:[String:Any]=["kind":game.kind.rawValue,"white":entry.white,"black":entry.black,"seed":entry.seed,"plies":game.history.count,"winner":game.winner ?? "-","draw":game.drawReason ?? "-",
                "facts":review.facts.map(\.text),"factCount":review.facts.count,"factsOverOneMove":review.facts.filter{$0.plies>2}.count,"cpuSeconds":cpu,"wallSeconds":elapsed,"nodes":review.nodes,
                "maxRootNodes":review.answers.values.map(\.nodes).max() ?? 0,"exhaustedRoots":review.answers.values.filter(\.exhausted).count,"entries":review.entries,"rootsSearched":review.answers.count,
                "roots":game.history.count+1,"exactRoots":exact,"complete":review.complete,"peakFootprintDeltaBytes":Int(peak)-Int(baseline)]
            games.append(row)
            var tally=perKind[game.kind.rawValue] ?? [:];tally["games",default:0]+=1
            if decisive{tally["decisive",default:0]+=1;if !review.facts.isEmpty{tally["decisiveWithFact",default:0]+=1};if review.facts.contains(where:{$0.plies>2}){tally["decisiveWithLongerFact",default:0]+=1}}
            perKind[game.kind.rawValue]=tally
            print("SPIKE \(game.kind.rawValue) \(entry.white)-\(entry.black) seed \(entry.seed): plies \(game.history.count) winner \(game.winner ?? "-") facts \(review.facts.count) cpu \(String(format:"%.2f",cpu))s nodes \(review.nodes) searched \(review.answers.count)/\(game.history.count+1) complete \(review.complete)")
        }
        // Quiet positions (each start, and the corpus's positions ten plies in) and delayed finishes (a pawn one step
        // from the far rank, or a pending finish), each searched alone at the full per-root budget.
        var roots:[[String:Any]]=[]
        func measure(_ label:String,_ state:MiniGameState){
            var proof=MiniGameProof(kind:state.kind);let start=Self.cpuSeconds(),answer=proof.prove(state,historyComplete:true),cpu=Self.cpuSeconds()-start
            roots.append(["label":label,"kind":state.kind.rawValue,"result":String(describing:answer.result),"nodes":answer.nodes,"exhausted":answer.exhausted,"clearPlies":answer.clearPlies,"cpuSeconds":cpu,"nodesPerSecond":Double(answer.nodes)/max(cpu,1e-9),"entries":proof.entryCount])
        }
        for kind in MiniGameKind.allCases where !kind.solo {
            measure("start",MiniGameState(kind:kind))
            for entry in corpus where entry.kind==kind && entry.seed==1 {
                guard let positions=MiniGameReview.positions(of:entry.game) else{continue}
                if positions.count>10{measure("quiet ply 10 \(entry.white)-\(entry.black)",positions[10])}
                if let delayed=positions.firstIndex(where:{s in s.snapshot.pendingFinish != nil || s.board.contains{$0.value==s.turn+"p" && $0.key.hasSuffix(s.turn=="w" ? "7":"2")}}){measure("delayed ply \(delayed) \(entry.white)-\(entry.black)",positions[delayed])}
            }
        }
        // Cancellation: a review stopped 150 ms in returns within the plan's 100 ms.
        var latencies:[String:Double]=[:]
        for kind in MiniGameKind.allCases where !kind.solo {
            let game=try XCTUnwrap(corpus.first{$0.kind==kind && $0.white=="standard" && $0.black=="challenging"}?.game)
            final class Flag:@unchecked Sendable {let lock=NSLock(),done=DispatchSemaphore(value:0);var stopAt:Date?,returned=Date()
                var stopped:Bool {lock.lock();defer{lock.unlock()};return stopAt != nil}}
            let flag=Flag()
            Thread.detachNewThread{
                _ = MiniGameReview.run(game,budget:60,cpuSeconds:Self.cpuSeconds,stop:{flag.stopped})
                flag.returned=Date();flag.done.signal()
            }
            Thread.sleep(forTimeInterval:0.15);flag.lock.lock();flag.stopAt=Date();flag.lock.unlock();flag.done.wait()
            latencies[kind.rawValue]=flag.returned.timeIntervalSince(flag.stopAt!)*1000
        }
        let decisive=perKind.values.reduce(0){$0+($1["decisive"] ?? 0)},useful=perKind.values.reduce(0){$0+($1["decisiveWithFact"] ?? 0)}
        let cpu=games.compactMap{$0["cpuSeconds"] as? Double}.sorted(),rootNodes=games.compactMap{$0["maxRootNodes"] as? Int}
        let summary:[String:Any]=["budget":["plies":MiniGameProofBudget.plies,"nodesPerRoot":MiniGameProofBudget.nodesPerRoot,"reviewCPUSeconds":MiniGameProofBudget.reviewCPUSeconds,"cancellationMilliseconds":MiniGameProofBudget.cancellationMilliseconds],
            "rulesVersion":MiniGameRules.version,"corpusGenerationSeconds":generation,"games":games.count,"decisive":decisive,"decisiveWithFact":useful,"usefulness":Double(useful)/Double(max(decisive,1)),"perKind":perKind,
            "reviewCPUSecondsMax":cpu.last ?? 0,"reviewCPUSecondsMedian":cpu.isEmpty ? 0:cpu[cpu.count/2],"maxRootNodes":rootNodes.max() ?? 0,"cancellationMilliseconds":latencies,
            "peakFootprintDeltaBytesMax":games.compactMap{$0["peakFootprintDeltaBytes"] as? Int}.max() ?? 0]
        try JSONSerialization.data(withJSONObject:["summary":summary,"games":games,"roots":roots],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        print("SPIKE SUMMARY \(String(decoding:try JSONSerialization.data(withJSONObject:summary,options:[.sortedKeys]),as:UTF8.self))")
        XCTAssertGreaterThan(decisive,0)
        XCTAssertGreaterThanOrEqual(Double(useful),Double(decisive)/2,"usefulness gate: at least half the decisive games yield a proven fact")
        for (kind,latency) in latencies {XCTAssertLessThanOrEqual(latency,Double(MiniGameProofBudget.cancellationMilliseconds),kind)}
        XCTAssertLessThanOrEqual(rootNodes.max() ?? 0,MiniGameProofBudget.nodesPerRoot)
    }
}
