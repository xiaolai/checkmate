import CheckmateTestSupport
import XCTest
import CheckmateCore
@testable import CheckmateDomain
@testable import CheckmateRules
@testable import CheckmateApplication

/// WI-002: generated scenarios against structurally different references (chess.js's own attack test and move
/// generator), the provider's freshness rules and measured latency.
@MainActor final class TrainingScenarioTests:XCTestCase {
    private var runtime:JavaScriptCoreChessRuntime!
    override func setUp() async throws {runtime=try JavaScriptCoreChessRuntime()}
    private func json(_ value:Any)throws -> String {String(decoding:try JSONSerialization.data(withJSONObject:value,options:.sortedKeys),as:UTF8.self)}
    /// chess.js's `attackers` on the same diagram, placed with `put`.
    private func referenceAttackers(_ board:Position,target:String,color:String)throws -> Set<String> {
        let output=try runtime.evaluate("(()=>{const i=\(try json(["board":board,"target":target,"color":color]));const g=new exports.Chess();g.clear();for(const [s,p] of Object.entries(i.board)){if(!g.put({color:p[0],type:p[1]},s))throw Error('put '+s)};return JSON.stringify(g.attackers(i.target,i.color))})()")
        return Set(try JSONDecoder().decode([String].self,from:Data(output.utf8)))
    }
    /// A breadth-first search over chess.js's pseudo-legal move generator: a different move generator, a different
    /// language and a different castling test (`isAttacked`).
    private func referenceDistance(_ drill:MovementDrill)throws -> Int? {
        let input=try json(["piece":drill.piece,"start":drill.start,"target":drill.target,"pieces":drill.pieces])
        let script="""
        (()=>{const i=\(input),color=i.piece[0],enemy=color==='w'?'b':'w',alg=n=>'abcdefgh'[n&7]+(8-(n>>4));
        const game=(sq,cap)=>{const g=new exports.Chess();g.clear();for(const [s,p] of Object.entries(i.pieces)){if(!cap.includes(s)&&!g.put({color:p[0],type:p[1]},s))throw Error('put')}if(!g.put({color,type:i.piece[1]},sq))throw Error('put piece');const f=g.fen().split(' ');f[1]=color;f[2]='-';f[3]='-';return new exports.Chess(f.join(' '),{skipValidation:true})};
        const key=(sq,cap)=>sq+'|'+[...cap].sort().join(',');let frontier=[[i.start,[]]],seen=new Set([key(i.start,[])]),depth=0;
        while(frontier.length){if(frontier.some(([s])=>s===i.target))return depth;depth++;const next=[];
          for(const [sq,cap] of frontier){if(sq===i.target||i.piece[1]==='p'&&(sq[1]==='1'||sq[1]==='8'))continue;const g=game(sq,cap);
            for(const m of g._moves({legal:false,square:sq})){const to=alg(m.to),taken=g.get(to)?[...cap,to]:cap;
              if(i.piece[1]==='k'){const after=new exports.Chess(g.fen(),{skipValidation:true});after.remove(sq);after.remove(to);after.put({color,type:'k'},to);if(after.isAttacked(to,enemy))continue}
              const k=key(to,taken);if(!seen.has(k)){seen.add(k);next.push([to,taken])}}}
          frontier=next}
        return -1})()
        """
        let value=Int(try runtime.evaluate(script)) ?? -2;return value<0 ? nil:value
    }
    func testReferencesAgreeOnHandCheckedCases()throws {
        XCTAssertEqual(try referenceAttackers(["e1":"wk","d2":"wn","a5":"bb","e4":"bp","e8":"bk"],target:"e4",color:"w"),["d2"],"chess.js also counts a pinned attacker")
        XCTAssertEqual(try referenceDistance(MovementDrill(piece:"wn",start:"a1",target:"b2",pieces:[:])),4)
        XCTAssertEqual(try referenceDistance(MovementDrill(piece:"wk",start:"e1",target:"e3",pieces:["d8":"br"])),2)
        // e3 is covered by the rook while the protected knight blocks: the king must walk round and take the rook first.
        let detour=MovementDrill(piece:"wk",start:"e1",target:"e3",pieces:["e2":"bn","e8":"br"])
        XCTAssertEqual(try referenceDistance(detour),12);XCTAssertEqual(detour.distance(from:detour.initial),12)
        XCTAssertNil(try referenceDistance(MovementDrill(piece:"bp",start:"d7",target:"d4",pieces:["d6":"wn"])))
    }
    func testThousandSeedsPerGeneratorAndTier()throws {
        let catalog=try TrainingCatalog.bundled(),pieces=["p","n","b","r","q","k"]
        var report:[String]=[]
        for (name,entry) in [("reach","reach-target"),("attackers","find-attackers"),("defenders","find-defenders")] {
            let definition=try XCTUnwrap(catalog.entry(entry))
            for tier in 1...3 {
                var exhausted=0,empty=0,clusters=Set<String>(),referenced=0,colors=Set<String>(),candidates=0
                for seed in 0..<1000 {
                    let color:Character=seed%2==0 ? "w":"b"
                    let made:TrainingScenario?
                    switch name {
                    case "reach":made=TrainingGenerator.reachTarget(seed:UInt64(seed),tier:tier,color:color,piece:pieces[seed%pieces.count])
                    case "attackers":made=TrainingGenerator.findAttackers(seed:UInt64(seed),tier:tier,color:color)
                    default:made=TrainingGenerator.findDefenders(seed:UInt64(seed),tier:tier,color:color)
                    }
                    guard let scenario=made else{exhausted+=1;continue}
                    try TrainingValidationService.validate(scenario,definition:definition)
                    clusters.insert(scenario.cluster);colors.insert(scenario.learner);candidates+=scenario.generation?.candidates ?? 0
                    XCTAssertEqual(scenario.tier,tier);XCTAssertLessThanOrEqual(scenario.generation?.candidates ?? 99,TrainingGenerator.candidateCap)
                    if name=="reach" {
                        let drill=try XCTUnwrap(scenario.drill),distance=try XCTUnwrap(scenario.expected?.distance)
                        XCTAssertEqual(scenario.shortest==true,tier==3,"only tier 3 asks for the fewest moves");XCTAssertEqual(scenario.budget,distance+(tier==1 ? 2:tier==2 ? 1:0))
                        if seed%4==0 {XCTAssertEqual(try referenceDistance(drill),distance,scenario.id);referenced+=1}
                        if drill.piece.last=="p"{XCTAssertTrue(drill.color=="w" ? drill.target.last! > drill.start.last!:drill.target.last! < drill.start.last!,"a pawn drill always runs forward for its colour")}
                    } else {
                        let answer=Set(scenario.expected?.squares ?? []),board=try XCTUnwrap(scenario.diagram),target=try XCTUnwrap(scenario.target)
                        XCTAssertEqual(try referenceAttackers(board,target:target,color:scenario.learner),answer,scenario.id);referenced+=1
                        if answer.isEmpty{empty+=1}
                        if tier==1{XCTAssertFalse(answer.isEmpty,"tier 1 always has an answer to find")}
                        if tier>1{XCTAssertFalse(TrainingGenerator.lookalikes(board,target:target,color:Character(scenario.learner)).isEmpty,"later tiers include a piece that only looks like an answer")}
                    }
                }
                XCTAssertLessThanOrEqual(exhausted,10,"\(name) tier \(tier): at most 1% of seeds exhaust the 64-candidate cap")
                XCTAssertGreaterThanOrEqual(Double(clusters.count),0.95*Double(1000-exhausted),"\(name) tier \(tier): seeds give distinct boards");XCTAssertEqual(colors,["w","b"])
                if name != "reach",tier>1{XCTAssertGreaterThan(empty,50,"\(name) tier \(tier) includes intentional empty sets")}
                report.append("\(name) t\(tier): exhausted=\(exhausted) distinct=\(clusters.count) empty=\(empty) referenced=\(referenced) meanCandidates=\(String(format:"%.1f",Double(candidates)/Double(max(1,1000-exhausted))))")
            }
        }
        print("TRAINING-GENERATORS "+report.joined(separator:" | "))
    }
    func testProviderOffersPoolThenReserveThenLabelledRepeats()throws {
        let catalog=try TrainingCatalog.bundled(),definition=try XCTUnwrap(catalog.entry("mate-in-one"))
        func mate(_ id:String,_ cluster:String,_ fen:String,_ moves:[String],reserve:Bool=false)->TrainingScenario {TrainingScenario(id:id,entry:"mate-in-one",variant:"mate",tier:1,cluster:cluster,learner:String(fen.split(separator:" ")[1]),prompt:"Mate in one.",explanation:"Mate.",hints:["Look for checks."],fen:fen,expected:TrainingExpected(moves:moves),reserve:reserve,review:TrainingReview(author:"test",reviewer:nil,validatorVersion:TrainingValidationService.validatorVersion))}
        let scenarios=[mate("pool-a","back-rank","6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1",["a1a8"]),mate("pool-b","back-rank","7k/6pp/8/8/8/8/8/RR4K1 w - - 0 1",["a1a8","b1b8"]),mate("reserve-a","promotion","6br/5Ppk/6pp/8/8/8/8/K7 w - - 0 1",["f7f8n"],reserve:true)]
        for scenario in scenarios{try TrainingValidationService.validate(scenario,definition:definition)}
        let provider=try TrainingScenarioProvider(catalog:catalog,scenarios:scenarios)
        guard case .scenario(let first,.new)=provider.next(for:definition,seen:[],seed:1) else{return XCTFail("the practice pool comes first")}
        XCTAssertNotEqual(first.reserve,true)
        guard case .scenario(let reserved,.reserve)=provider.next(for:definition,seen:["back-rank"],seed:1) else{return XCTFail("reserved clusters follow")}
        XCTAssertEqual(reserved.id,"reserve-a")
        guard case .scenario(_,.repeat)=provider.next(for:definition,seen:["back-rank","promotion"],seed:1) else{return XCTFail("exhausted material is labelled repeat, never fresh")}
        provider.suspend("reserve-a");provider.suspend("pool-a");provider.suspend("pool-b")
        XCTAssertEqual(provider.next(for:definition,seen:[],seed:1),.exhausted);XCTAssertFalse(provider.available(definition),"withdrawn content is not offered")
        XCTAssertThrowsError(try TrainingScenarioProvider(catalog:catalog,scenarios:[scenarios[0],scenarios[0]]),"duplicate identifiers")
        // A tampered oracle is rejected by revalidation.
        let tampered=mate("tampered","back-rank-2","7k/6pp/8/8/8/8/8/RR4K1 w - - 0 1",["a1a8"])
        XCTAssertThrowsError(try TrainingValidationService.validate(tampered,definition:definition),"an incomplete accepted set would mark a correct alternative wrong")
        let stale=TrainingScenario(id:"stale",entry:"mate-in-one",variant:"mate",tier:1,cluster:"x",learner:"w",prompt:"p",explanation:"e",hints:["h"],fen:"6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1",expected:TrainingExpected(moves:["a1a8"]),review:TrainingReview(author:"test",reviewer:nil,validatorVersion:99))
        XCTAssertThrowsError(try TrainingValidationService.validate(stale,definition:definition),"content validated by another validator version")
    }
    func testGeneratedEntriesAreAlwaysAvailableAndHonestOnExhaustion()throws {
        let catalog=try TrainingCatalog.bundled(),provider=try TrainingScenarioProvider(catalog:catalog,scenarios:[])
        for id in ["reach-target","find-attackers","find-defenders","pawn-duel"] {XCTAssertTrue(provider.available(try XCTUnwrap(catalog.entry(id))),id)}
        XCTAssertFalse(provider.available(try XCTUnwrap(catalog.entry("mate-in-one"))),"no curated content, no entry")
        guard case .scenario(let made,.new)=provider.next(for:try XCTUnwrap(catalog.entry("reach-target")),seen:[],seed:9,tier:2,variant:"rook") else{return XCTFail()}
        XCTAssertEqual(made.drill?.piece.last,"r");XCTAssertEqual(made.tier,2)
        guard case .scenario(let again,.repeat)=provider.next(for:try XCTUnwrap(catalog.entry("reach-target")),seen:[made.cluster],seed:9,tier:2,variant:"rook") else{return XCTFail()}
        XCTAssertEqual(again,made,"the same seed is the same concrete board, labelled a repeat")
    }
    func testMeasuredSetupAndSubmissionLatency()throws {
        let fens=["6k1/5ppp/8/8/8/8/8/R5K1 w - - 0 1","7k/6pp/8/8/8/8/8/RR4K1 w - - 0 1","6br/5Ppk/6pp/8/8/8/8/K7 w - - 0 1","4k3/8/8/8/8/2N5/3PPP2/r3K3 w - - 0 1","4k3/4r3/8/8/8/8/4N3/4K2r w - - 0 1","k7/8/8/8/8/8/3n4/4K3 w - - 0 1","r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 2 3","rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"]
        var setup:[Double]=[],submit:[Double]=[]
        for index in 0..<240 {
            let fen=fens[index%fens.count],started=Date()
            let legality=try TrainingLegality(fen:fen);_ = try legality.outcomes()
            setup.append(Date().timeIntervalSince(started)*1000)
            let move=try XCTUnwrap(try legality.outcomes().first),graded=Date()
            _ = try legality.grade(from:move.from,to:move.to,promotion:move.promotion);_ = try legality.status()
            submit.append(Date().timeIntervalSince(graded)*1000)
        }
        func p95(_ values:[Double])->Double {values.sorted()[Int(Double(values.count)*0.95)]}
        print("TRAINING-LATENCY cases=\(setup.count) setupP95Ms=\(String(format:"%.1f",p95(setup))) setupMaxMs=\(String(format:"%.1f",setup.max()!)) submitP95Ms=\(String(format:"%.2f",p95(submit))) submitMaxMs=\(String(format:"%.2f",submit.max()!))")
        XCTAssertLessThan(p95(setup),100,"proposed setup budget: p95 under 100 ms");XCTAssertLessThan(p95(submit),16,"proposed submission budget: p95 under 16 ms")
    }
}
