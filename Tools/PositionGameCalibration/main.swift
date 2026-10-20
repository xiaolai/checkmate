import Foundation
import CryptoKit
import CheckmateDomain
import CheckmateRules
import CheckmateEngine
import CheckmateApplication

// Plays the standard-rule calibration manifest (mini-game plan D4, WI-020) on the test host with the bundled Stockfish,
// and writes its results as JSON.
//   swift run -c release CheckmatePositionGameCalibration [--manifest PATH] [--output PATH] [--games N] [--only KEY,...] [--workers N]
//   swift run -c release CheckmatePositionGameCalibration witness [--nodes N] [--seed HEX]
// The games run in `--workers` child processes of this program (`--shard K/N --partial PATH`), each with its own main
// thread, rules runtime and engine process, playing every Nth game one after another; the parent merges their outcomes.
// One process would serialise every game's rules work on its one main actor. Steady (skill 3) uses Stockfish's own
// unseeded randomness, so a rerun differs move for move; Gentle, Strong and the references are seeded. `--games` or
// `--only` makes a smoke run, marked as such: the offering never takes its levels from one.
// `witness` prints, for every authored checkmate position game, a line from its start to a position in which Strong's
// search at `--nodes` reports a forced mate for the learner (an empty line when the start has one), against seeded
// random replies; Content/training/position-game-evidence.json records them and PositionGameContentTests repeats each
// search.
// The test host carries ~/.config/checkmate/host-role naming "test", the marker scripts/test_host.py reads.
let hostRoles=Set(((try? String(contentsOf:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/checkmate/host-role"),encoding:.utf8)) ?? "").split(whereSeparator:\.isWhitespace).map(String.init))
guard hostRoles.contains("test") else{FileHandle.standardError.write(Data("Run position-game calibration on the test host only.\n".utf8));exit(2)}

func fail(_ message:String)->Never {FileHandle.standardError.write(Data((message+"\n").utf8));exit(1)}
func log(_ message:String){FileHandle.standardError.write(Data((message+"\n").utf8))}
func sha256(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
var arguments=Array(CommandLine.arguments.dropFirst()),options:[String:String]=[:]
let witnessMode=arguments.first=="witness";if witnessMode{arguments.removeFirst()}
let allowed=witnessMode ? ["--nodes","--seed"]:["--manifest","--output","--games","--only","--workers","--shard","--partial"]
while let flag=arguments.first {
    guard allowed.contains(flag),arguments.count>=2 else{fail("Unknown or incomplete argument \(flag)")}
    options[flag]=arguments[1];arguments.removeFirst(2)
}
let settings=options

// MARK: Witness lines

/// The authored scenarios in Content/training/scenarios: the evidence belongs to the sources, which cannot be published
/// before it exists.
func authored()throws -> [TrainingScenario] {
    struct Document:Decodable {let scenarios:[TrainingScenario]}
    let folder=URL(fileURLWithPath:"Content/training/scenarios")
    return try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}.sorted{$0.lastPathComponent<$1.lastPathComponent}
        .flatMap{try JSONDecoder().decode(Document.self,from:Data(contentsOf:$0)).scenarios}
}
@MainActor func witnesses()async throws {
    guard let nodes=Int(settings["--nodes"] ?? "1000000"),(1000...5_000_000).contains(nodes),let seed=UInt64(settings["--seed"] ?? "5eed",radix:16) else{fail("--nodes must be 1000...5000000 and --seed hexadecimal")}
    let engine=NativeEngine();try await engine.prepare()
    var records:[String:[String:Any]]=[:]
    for scenario in try authored() where scenario.check == .positionGame && scenario.goal?.kind == .checkmate {
        guard let fen=scenario.fen else{fail("\(scenario.id) has no FEN")}
        let rules=try ChessRules(fen:fen),sign=scenario.learner=="w" ? 1:-1;var line:[String]=[],found:AnalysisScore?
        while line.count<400 {
            let result=try await engine.analyzeHistory(startFEN:fen,moves:line,profile:.skill(20),limit:.nodes(nodes),multiPv:1,searchMoves:[])
            guard let score=result.lines.first?.score else{fail("\(scenario.id): no score after \(line)")}
            if score.kind=="mate",score.value*sign>0{found=score;break}
            guard let move=result.bestMove else{fail("\(scenario.id): no move after \(line)")}
            try rules.move(uci:move);line.append(move)
            guard !rules.over else{fail("\(scenario.id): the game ended before a mate score: \(line)")}
            var random=TrainingRandom(seed:seed &+ UInt64(line.count));let reply=random.pick(rules.moves()).uci
            try rules.move(uci:reply);line.append(reply)
            guard !rules.over else{fail("\(scenario.id): the game ended before a mate score: \(line)")}
        }
        guard let found else{fail("\(scenario.id): no mate score within 400 plies")}
        records[scenario.id]=["line":line,"nodes":nodes,"mate":found.value*sign]
        log("\(scenario.id): mate in \(found.value*sign) after \(line.count) plies")
    }
    let output:[String:Any]=["schemaVersion":1,"engine":engine.binaryIdentity,"mates":records]
    print(String(decoding:try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
}

// MARK: Calibration

/// One game to play: the entry, the pairing, its index, and the side, start and seed that follow from them.
struct Job {let entry:PositionGameCalibration.Entry,level:TrainingOpponentLevel,reference:String,index:Int,side:String,start:PositionGameCalibration.Start,seed:UInt64
    /// The learner's colour for this start: a guided game names it, every other entry has one for all its starts.
    var learner:String {start.learner(of:entry)}
}
/// How one game ended: its job's index, the referee's row (nil at the ply cap), its length and how long it took.
struct Played:Codable {let index:Int,row:PositionGameRow?,plies:Int,seconds:Double}
/// One shard: plays every `count`th game from `shard`, one after another with one engine, and returns the outcomes.
@MainActor func play(_ jobs:[Job],shard:Int,count:Int,provider:TrainingScenarioProvider,maximumPlies:Int)async throws -> [Played] {
    let engine=NativeEngine();try await engine.prepare()
    let mine=Array(stride(from:shard,to:jobs.count,by:count)),all=TrainingOpponentLevel.allCases,started=Date()
    var played:[Played]=[]
    for index in mine {
        let job=jobs[index]
        guard let scenario=provider.scenario(job.start.scenario) else{fail("\(job.start.scenario) is not published")}
        let rules=try PositionGameMatch.rules(of:scenario),me=PositionGameMatch.Player.level(job.level,engine:engine,seed:job.seed)
        let them:PositionGameMatch.Player
        switch job.reference {
        case "random":them = .random(seed:job.seed ^ 0x5eed)
        case "greedy":them = .greedy(seed:job.seed ^ 0x5eed)
        default:them = .level(all[all.firstIndex(of:job.level)!-1],engine:engine,seed:job.seed ^ 0xbe10)
        }
        let clock=Date()
        let outcome=try await PositionGameMatch.play(start:job.start.fen,goal:rules.goal,keep:rules.keep,learner:job.learner,white:job.side=="w" ? me:them,black:job.side=="w" ? them:me,maximumPlies:maximumPlies)
        played.append(Played(index:index,row:outcome.row,plies:outcome.plies,seconds:Date().timeIntervalSince(clock)))
        if played.count%25==0 || played.count==mine.count{log("shard \(shard)/\(count): \(played.count)/\(mine.count) games, \(Int(Date().timeIntervalSince(started)))s")}
    }
    return played
}
/// Runs `count` shards as child processes of this program and merges their outcomes; any shard's failure fails the run.
func shards(_ count:Int,jobs:Int)throws -> [Played] {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("position-calibration-\(ProcessInfo.processInfo.processIdentifier)")
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
    let passed=settings.filter{["--manifest","--games","--only"].contains($0.key)}.sorted{$0.key<$1.key}.flatMap{[$0.key,$0.value]}
    let children=try (0..<count).map{shard->(Process,URL) in
        let process=Process(),partial=directory.appendingPathComponent("\(shard).json")
        process.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath();process.arguments=passed+["--shard","\(shard)/\(count)","--partial",partial.path]
        try process.run();return (process,partial)
    }
    var played:[Played]=[]
    for (process,partial) in children {
        process.waitUntilExit()
        guard process.terminationStatus==0,let data=FileManager.default.contents(atPath:partial.path) else{fail("A calibration shard failed (exit \(process.terminationStatus)).")}
        played+=try JSONDecoder().decode([Played].self,from:data)
    }
    guard played.map(\.index).sorted()==Array(0..<jobs) else{fail("The shards did not play every game exactly once.")}
    return played.sorted{$0.index<$1.index}
}

@MainActor func calibrate(_ provider:TrainingScenarioProvider)async throws {
    let manifestPath=settings["--manifest"] ?? "Content/calibration/position-game-manifest.json",outputPath=settings["--output"] ?? "Content/calibration/position-game-results.json"
    guard let manifestData=FileManager.default.contents(atPath:manifestPath) else{fail("No manifest at \(manifestPath)")}
    let manifest:PositionGameCalibration.Manifest
    do {manifest=try JSONDecoder().decode(PositionGameCalibration.Manifest.self,from:manifestData)} catch {fail("Unreadable manifest: \(error)")}
    // The manifest is checked before any game is played, its starts against the published scenarios too.
    var problems=PositionGameCalibration.problems(manifest)
    for entry in manifest.entries {for start in entry.starts {
        guard let scenario=provider.scenario(start.scenario) else{problems.append("\(entry.key): \(start.scenario) is not published");continue}
        if scenario.fen != start.fen || scenario.entry != entry.entry || scenario.variant != entry.variant || scenario.check != entry.check || scenario.learner != start.learner(of:entry){problems.append("\(entry.key): \(start.scenario) differs from the published scenario")}
    }}
    guard problems.isEmpty else{fail("Invalid manifest:\n- "+problems.joined(separator:"\n- "))}
    let games=settings["--games"].map{Int($0) ?? -1} ?? manifest.gamesPerPairing
    guard games>0,games%2==0 else{fail("--games must be a positive even number")}
    let only=settings["--only"].map{Set($0.split(separator:",").map(String.init))}
    let entries=manifest.entries.filter{only?.contains($0.key) ?? true}
    guard !entries.isEmpty,only.map({$0.isSubset(of:Set(manifest.entries.map(\.key)))}) ?? true else{fail("--only names an entry the manifest does not have")}
    let smoke=games != manifest.gamesPerPairing || only != nil
    let seed=UInt64(manifest.seed,radix:16)!,cores=ProcessInfo.processInfo.activeProcessorCount
    guard let workers=Int(settings["--workers"] ?? String(cores)),(1...64).contains(workers) else{fail("--workers must be 1...64")}
    // A guided game's start names the learner, so the level plays the other side and the starts take turns. Every other
    // entry plays White in the first half of a two-sided pairing and Black in the second; its starts take turns.
    let jobs=entries.flatMap{entry in PositionGameCalibration.pairings(manifest,entry).flatMap{pairing in (0..<games).map{index->Job in
        let start=entry.sidesFollowStarts ? entry.starts[index%entry.starts.count]:entry.starts[(index%(games/entry.sides.count))%entry.starts.count]
        let side=entry.sidesFollowStarts ? (start.learner(of:entry)=="w" ? "b":"w"):entry.sides[index/(games/entry.sides.count)]
        return Job(entry:entry,level:pairing.level,reference:pairing.reference,index:index,side:side,start:start,seed:PositionGameCalibration.seed(seed,entry.key,"\(pairing.level.rawValue)|\(pairing.reference)",index))
    }}}
    if let shard=settings["--shard"] {
        let parts=shard.split(separator:"/").compactMap{Int($0)}
        guard parts.count==2,(0..<parts[1]).contains(parts[0]),let partial=settings["--partial"] else{fail("--shard K/N needs 0 <= K < N and --partial PATH")}
        let played=try await play(jobs,shard:parts[0],count:parts[1],provider:provider,maximumPlies:manifest.maximumPlies)
        try JSONEncoder().encode(played).write(to:URL(fileURLWithPath:partial),options:.atomic);return
    }
    let started=Date(),outcomes=try shards(workers,jobs:jobs.count),seconds=Date().timeIntervalSince(started)
    let all=outcomes.map{(job:jobs[$0.index],played:$0)}
    let identity=NativeEngine();try await identity.prepare()

    var results:[PositionGameCalibration.EntryResult]=[],perEntry:[String:[String:Double]]=[:]
    for entry in entries {
        let mine=all.filter{$0.job.entry.key==entry.key}
        let rows=PositionGameCalibration.pairings(manifest,entry).map{pairing->MiniGameCalibration.Pairing in
            var white=MiniGameCalibration.Tally(),black=MiniGameCalibration.Tally()
            for game in mine where game.job.level==pairing.level && game.job.reference==pairing.reference {
                let row=game.played.row,result=MiniGameCalibration.Game(winner:PositionGameCalibration.winner(row,learner:game.job.learner,scoring:entry.scoring),plies:game.played.plies,adjudicated:row==nil)
                if game.job.side=="w"{white.add(result,side:"w")}else{black.add(result,side:"b")}
            }
            return MiniGameCalibration.Pairing(level:pairing.level.rawValue,reference:pairing.reference,asWhite:white,asBlack:black)
        }
        results.append(PositionGameCalibration.EntryResult(entry:entry.entry,variant:entry.variant,pairings:rows))
        perEntry[entry.key]=["games":Double(mine.count),"gameSeconds":mine.map(\.played.seconds).reduce(0,+),"plies":Double(mine.map(\.played.plies).reduce(0,+))]
    }
    var playedManifest=manifest;playedManifest.gamesPerPairing=games
    let verdicts=try results.map{try PositionGameCalibration.verdict($0,manifest:playedManifest)}
    // How each pairing's games ended, by the referee's row, so a verdict can be read back to its games.
    var endings:[String:[String:Int]]=[:]
    for game in all {endings["\(game.job.entry.key)|\(game.job.level.rawValue)|\(game.job.reference)",default:[:]][game.played.row?.rawValue ?? "plyCap",default:0]+=1}

    // Identity: the engine, its options and node limits, the sources that decide a game, and the machine (no names).
    let sources=Dictionary(uniqueKeysWithValues:(PositionGameCalibration.sourceFiles+[manifestPath]).map{path->(String,String) in guard let data=FileManager.default.contents(atPath:path) else{fail("Missing source \(path)")};return (path,sha256(data))})
    func sysctl(_ name:String)->String {var size=0;sysctlbyname(name,nil,&size,nil,0);var bytes=[CChar](repeating:0,count:max(1,size));sysctlbyname(name,&bytes,&size,nil,0);return String(cString:bytes)}
    struct Identity:Encodable {let engine:String,engineName:String,options:[String:String],nodeLimits:[String:String],sourceSHA256:[String:String],os:String,cpu:String,cores:Int,workers:Int,date:String}
    struct Timing:Encodable {let seconds:Double,perEntry:[String:[String:Double]]}
    struct Output:Encodable {
        let manifest:PositionGameCalibration.Manifest,entries:[PositionGameCalibration.EntryResult],verdicts:[PositionGameCalibration.Verdict],smoke:Bool
        /// The fewest games per pairing at which a level at the head-to-head minimum can pass, and the least difference
        /// that always separates two intervals at the sample played.
        let requiredGamesPerPairing:Int,separatingDifference:Double
        let endings:[String:[String:Int]],identity:Identity,timing:Timing,notes:[String]
    }
    let limits=Dictionary(uniqueKeysWithValues:TrainingOpponentLevel.allCases.map{($0.rawValue,TrainingOpponentConfiguration.frozen($0,attempt:"calibration",seed:1).policy)}),rule=manifest.passRule
    let output=Output(manifest:playedManifest,entries:results,verdicts:verdicts,smoke:smoke,requiredGamesPerPairing:PositionGameCalibration.requiredGames(rule.headToHead,confidence:rule.confidence),separatingDifference:PositionGameCalibration.separatingDifference(games:games,confidence:rule.confidence),endings:endings,
        identity:Identity(engine:identity.binaryIdentity,engineName:identity.capabilities.name,options:AnalysisPolicy.options,nodeLimits:limits,sourceSHA256:sources,os:ProcessInfo.processInfo.operatingSystemVersionString,cpu:sysctl("machdep.cpu.brand_string"),cores:cores,workers:workers,date:ISO8601DateFormatter().string(from:Date())),
        timing:Timing(seconds:seconds,perEntry:perEntry),
        notes:["Scores are the level's points per game, counted from the level's side; asWhite and asBlack hold the games it played with each colour.",
               "Chess scoring: a win is a point and a draw half of one. Goal scoring: the learner's side scores a point only for a success row, as the app counts a draw as a failed goal, and the level scores the rest.",
               "Intervals are 95% Wilson score intervals on the score; with draws the true variance is lower, so they are conservative.",
               "Steady is Stockfish at skill 3, which uses its own unseeded randomness: its games are not reproducible move for move. Gentle (seeded), Strong (skill 20, one thread, a fresh hash per search) and the references (seeded) are.",
               "A level that only defends has no head-to-head game with the level below as the learner's side, so its pairs are decided by branch (a) alone."])
    let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
    let data=try encoder.encode(output)
    try FileManager.default.createDirectory(at:URL(fileURLWithPath:outputPath).deletingLastPathComponent(),withIntermediateDirectories:true)
    try data.write(to:URL(fileURLWithPath:outputPath),options:.atomic)
    for verdict in verdicts {log("\(verdict.entry)/\(verdict.variant): offers \(verdict.offered) (pairs \(verdict.pairs.map{"\($0.lower)-\($0.higher) \(String(format:"%.3f",$0.lowerScore))/\(String(format:"%.3f",$0.higherScore)) \($0.passedAgainstReference ? "pass (greedy)":$0.passedHeadToHead ? "pass (head-to-head \(String(format:"%.3f",$0.headToHeadScore)))":"fail")"}), greedy vs Gentle \(String(format:"%.3f",verdict.referenceScoreAgainstGentle)))")}
    log("wrote \(outputPath)\(smoke ? " (smoke run)":""), \(Int(seconds))s")
}

Task{@MainActor in
    do {
        if witnessMode{try await witnesses()}else{try await calibrate(try TrainingScenarioProvider.bundled())}
    } catch {fail("\(error)")}
    exit(0)
}
dispatchMain()
