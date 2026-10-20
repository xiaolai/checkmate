import Foundation
import CryptoKit
import CheckmateDomain

// Plays the mini-game calibration manifest (plan D4, WI-016) on the test host and writes its results as JSON.
//   swift run -c release CheckmateMiniGameCalibration [--manifest PATH] [--output PATH] [--games N] [--only GAME,...]
// The deterministic run plays every pairing with the search's deadline off, so a rerun gives the same games
// (`outcomesDigest`). The deadline run then plays each level with the production time limit while busy threads load
// every core, and counts how often the deadline cut the search and changed its move. `--games` or `--only` makes a
// smoke run, marked as such: the offering never takes its levels from one.
// The test host carries ~/.config/checkmate/host-role naming "test", the marker scripts/test_host.py reads.
let hostRoles=Set(((try? String(contentsOf:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/checkmate/host-role"),encoding:.utf8)) ?? "").split(whereSeparator:\.isWhitespace).map(String.init))
guard hostRoles.contains("test") else{FileHandle.standardError.write(Data("Run mini-game calibration on the test host only.\n".utf8));exit(2)}

func fail(_ message:String)->Never {FileHandle.standardError.write(Data((message+"\n").utf8));exit(1)}
func log(_ message:String){FileHandle.standardError.write(Data((message+"\n").utf8))}
var arguments=Array(CommandLine.arguments.dropFirst()),options:[String:String]=[:]
while let flag=arguments.first {
    guard ["--manifest","--output","--games","--only"].contains(flag),arguments.count>=2 else{fail("Unknown or incomplete argument \(flag)")}
    options[flag]=arguments[1];arguments.removeFirst(2)
}
let manifestPath=options["--manifest"] ?? "Content/calibration/mini-game-manifest.json"
let outputPath=options["--output"] ?? "Content/calibration/mini-game-results.json"
guard let manifestData=FileManager.default.contents(atPath:manifestPath) else{fail("No manifest at \(manifestPath)")}
let manifest:MiniGameCalibration.Manifest
do {manifest=try JSONDecoder().decode(MiniGameCalibration.Manifest.self,from:manifestData)} catch {fail("Unreadable manifest: \(error)")}
// The manifest is checked before any game is played.
let problems=MiniGameCalibration.problems(manifest)
guard problems.isEmpty else{fail("Invalid manifest:\n- "+problems.joined(separator:"\n- "))}
let games=options["--games"].map{Int($0) ?? -1} ?? manifest.gamesPerPairing
guard games>0,games%2==0 else{fail("--games must be a positive even number")}
let only=options["--only"].map{Set($0.split(separator:",").map(String.init))}
let entries=manifest.entries.filter{only?.contains($0.game) ?? true}
guard !entries.isEmpty,only.map({$0.isSubset(of:Set(manifest.entries.map(\.game)))}) ?? true else{fail("--only names a game the manifest does not have")}
let smoke=games != manifest.gamesPerPairing || only != nil
let seed=UInt64(manifest.seed,radix:16)!

/// Results gathered from concurrent games, each into its own slot.
final class Slots<Value>:@unchecked Sendable {
    private var values:[Value?];private let lock=NSLock()
    init(_ count:Int){values=Array(repeating:nil,count:count)}
    func set(_ index:Int,_ value:Value){lock.lock();values[index]=value;lock.unlock()}
    var all:[Value] {lock.lock();defer{lock.unlock()};return values.map{$0!}}
}
struct Job {let kind:MiniGameKind,level:String,reference:String,index:Int}
func player(_ reference:String,_ level:String)->MiniGameCalibration.Player {MiniGameCalibration.Player(reference:reference,below:level)!}
/// Plays `jobs` on every core. The level is White in the first half of a pairing's games and Black in the second.
func run(_ jobs:[Job],gamesPerPairing:Int,timeLimited:Bool,compareUntimed:Bool,label:String)->[MiniGameCalibration.Game] {
    let slots=Slots<MiniGameCalibration.Game>(jobs.count),counter=NSLock();var finished=0;let started=Date()
    DispatchQueue.concurrentPerform(iterations:jobs.count){i in
        let job=jobs[i],levelWhite=job.index<gamesPerPairing/2,me=MiniGameCalibration.Player.level(job.level),them=player(job.reference,job.level)
        let game=MiniGameCalibration.play(job.kind,white:levelWhite ? me:them,black:levelWhite ? them:me,seed:MiniGameCalibration.seed(seed,job.kind,"\(job.level)|\(job.reference)",job.index),maximumPlies:manifest.maximumPlies,timeLimited:timeLimited,compareUntimed:compareUntimed)
        slots.set(i,game);counter.lock();finished+=1;let n=finished;counter.unlock()
        if n%500==0 || n==jobs.count{log("\(label): \(n)/\(jobs.count) games, \(Int(Date().timeIntervalSince(started)))s")}
    }
    return slots.all
}

// The deterministic run: every pairing, deadline off.
let pairings=MiniGameCalibration.pairings(manifest)
let jobs=entries.flatMap{entry in pairings.flatMap{pairing in (0..<games).map{Job(kind:MiniGameKind(rawValue:entry.game)!,level:pairing.level,reference:pairing.reference,index:$0)}}}
let deterministicStart=Date()
let played=run(jobs,gamesPerPairing:games,timeLimited:false,compareUntimed:false,label:"deterministic")
let deterministicSeconds=Date().timeIntervalSince(deterministicStart)
var outcomes:UInt64=0xcbf29ce484222325
var results:[MiniGameCalibration.EntryResult]=[]
for entry in entries {
    let kind=MiniGameKind(rawValue:entry.game)!
    let rows=pairings.map{pairing->MiniGameCalibration.Pairing in
        var white=MiniGameCalibration.Tally(),black=MiniGameCalibration.Tally()
        for (job,game) in zip(jobs,played) where job.kind==kind && job.level==pairing.level && job.reference==pairing.reference {
            let side=job.index<games/2 ? "w":"b";if side=="w"{white.add(game,side:side)}else{black.add(game,side:side)}
            for byte in "\(entry.game)|\(job.level)|\(job.reference)|\(job.index)|\(game.winner ?? "-")|\(game.plies);".utf8{outcomes=(outcomes ^ UInt64(byte)) &* 0x100000001b3}
        }
        return MiniGameCalibration.Pairing(level:pairing.level,reference:pairing.reference,asWhite:white,asBlack:black)
    }
    results.append(MiniGameCalibration.EntryResult(game:entry.game,pairings:rows,policies:Dictionary(uniqueKeysWithValues:manifest.levels.map{($0,MiniOpponentPolicy.forGame(kind,profile:$0))})))
}
var playedManifest=manifest;playedManifest.gamesPerPairing=games
let verdicts=try results.map{try MiniGameCalibration.verdict($0,manifest:playedManifest)}

// The production-deadline run, under load: busy threads beside one game per core.
let cores=ProcessInfo.processInfo.activeProcessorCount,loadThreads=cores*manifest.deadline.loadThreadsPerCore
let stopLoad=Slots<Bool>(1);stopLoad.set(0,false)
for _ in 0..<loadThreads {Thread.detachNewThread{var x:UInt64=1;while !stopLoad.all[0]{for _ in 0..<100_000{x=x &* 6364136223846793005 &+ 1}};if x==0{log("")}}}
let deadlineJobs=entries.flatMap{entry in manifest.levels.flatMap{level in (0..<manifest.deadline.gamesPerLevel).map{Job(kind:MiniGameKind(rawValue:entry.game)!,level:level,reference:manifest.deadline.reference,index:$0)}}}
let deadlineStart=Date()
let timed=run(deadlineJobs,gamesPerPairing:manifest.deadline.gamesPerLevel,timeLimited:true,compareUntimed:true,label:"deadline")
let deadlineSeconds=Date().timeIntervalSince(deadlineStart);stopLoad.set(0,true)
struct DeadlineRow:Encodable {let game:String,level:String,games:Int,decisions:Int,deadlineCuts:Int,changedByDeadline:Int,cutRate:Double,changedRate:Double,milliseconds:Int}
let deadlineRows=entries.flatMap{entry in manifest.levels.map{level->DeadlineRow in
    let mine=zip(deadlineJobs,timed).filter{$0.0.kind.rawValue==entry.game && $0.0.level==level}.map(\.1)
    let decisions=mine.map(\.decisions).reduce(0,+),cuts=mine.map(\.deadlineCuts).reduce(0,+),changed=mine.map(\.changedByDeadline).reduce(0,+)
    return DeadlineRow(game:entry.game,level:level,games:mine.count,decisions:decisions,deadlineCuts:cuts,changedByDeadline:changed,cutRate:decisions==0 ? 0:Double(cuts)/Double(decisions),changedRate:decisions==0 ? 0:Double(changed)/Double(decisions),milliseconds:MiniOpponentPolicy.forGame(MiniGameKind(rawValue:entry.game)!,profile:level).milliseconds)
}}

// Identity: this binary, the sources that decide a game, and the machine (no names).
func sha256(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
let executable=URL(fileURLWithPath:CommandLine.arguments[0]).resolvingSymlinksInPath()
guard let binary=FileManager.default.contents(atPath:executable.path) else{fail("Cannot read this binary at \(executable.path)")}
let sourceFiles=MiniGameCalibration.sourceFiles+[manifestPath]
let sources=Dictionary(uniqueKeysWithValues:sourceFiles.map{path->(String,String) in guard let data=FileManager.default.contents(atPath:path) else{fail("Missing source \(path)")};return (path,sha256(data))})
func sysctl(_ name:String)->String {var size=0;sysctlbyname(name,nil,&size,nil,0);var bytes=[CChar](repeating:0,count:max(1,size));sysctlbyname(name,&bytes,&size,nil,0);return String(cString:bytes)}
struct Identity:Encodable {let binarySHA256:String,sourceSHA256:[String:String],os:String,cpu:String,cores:Int,date:String}
struct Timing:Encodable {let deterministicSeconds:Double,deadlineSeconds:Double,loadThreads:Int,gameThreads:Int}
struct Output:Encodable {
    let manifest:MiniGameCalibration.Manifest,entries:[MiniGameCalibration.EntryResult],verdicts:[MiniGameCalibration.Verdict],smoke:Bool
    /// The fewest games per pairing at which the 10-point rule, not the sample, decides (the manifest has at least this).
    let requiredGamesPerPairing:Int
    let outcomesDigest:String,identity:Identity,timing:Timing,deadline:[DeadlineRow]
    let notes:[String]
}
let output=Output(manifest:playedManifest,entries:results,verdicts:verdicts,smoke:smoke,requiredGamesPerPairing:MiniGameCalibration.requiredGames(minimumDifference:manifest.passRule.minimumDifference,confidence:manifest.passRule.confidence),outcomesDigest:String(format:"%016llx",outcomes),
    identity:Identity(binarySHA256:sha256(binary),sourceSHA256:sources,os:ProcessInfo.processInfo.operatingSystemVersionString,cpu:sysctl("machdep.cpu.brand_string"),cores:cores,date:ISO8601DateFormatter().string(from:Date())),
    timing:Timing(deterministicSeconds:deterministicSeconds,deadlineSeconds:deadlineSeconds,loadThreads:loadThreads,gameThreads:cores),deadline:deadlineRows,
    notes:["Scores are the level's points per game (a draw is half a point), counted from the level's side; asWhite and asBlack split each pairing evenly.",
           "Intervals are 95% Wilson score intervals on the score; with draws the true variance is lower, so they are conservative.",
           "The deterministic run has the search deadline off; the deadline run plays with the production limit under load and does not feed the verdicts."])
let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
let data=try encoder.encode(output)
try FileManager.default.createDirectory(at:URL(fileURLWithPath:outputPath).deletingLastPathComponent(),withIntermediateDirectories:true)
try data.write(to:URL(fileURLWithPath:outputPath),options:.atomic)
for verdict in verdicts {log("\(verdict.game): offers \(verdict.offered) (pairs \(verdict.pairs.map{"\($0.lower)-\($0.higher) \(String(format:"%.3f",$0.lowerScore))/\(String(format:"%.3f",$0.higherScore)) \($0.passedAgainstReference ? "pass (greedy)":$0.passedHeadToHead ? "pass (head-to-head \(String(format:"%.3f",$0.headToHeadScore)))":"fail")"}), greedy vs Gentle \(String(format:"%.3f",verdict.referenceScoreAgainstGentle)))")}
log("wrote \(outputPath)\(smoke ? " (smoke run)":"")")
