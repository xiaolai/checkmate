import CheckmateAssets
import CheckmateDomain
import CheckmateRules
import CheckmateSupport
import Foundation
import CryptoKit
import CoreFoundation

public struct ImportReport:Codable,Equatable {
    public var recovered:[String]=[],ignored:[String]=[],adjusted:[String]=[]
    public var duplicate=false
    public init(){}
    public var summary:String {duplicate ? String(localized:"This archive was already imported. Your newer progress is unchanged.",bundle:.checkmate):String(localized:"Recovered \(recovered.count) fields or records. Adjusted \(adjusted.count). Skipped \(ignored.count).",bundle:.checkmate)}
    public var details:String {
        [(String(localized:"Recovered",bundle:.checkmate),recovered),(String(localized:"Adjusted to supported values",bundle:.checkmate),adjusted),(String(localized:"Skipped",bundle:.checkmate),ignored)].filter{!$0.1.isEmpty}.map{title,items in title+"\n"+items.prefix(50).map{"• "+$0}.joined(separator:"\n")+(items.count>50 ? "\n"+String(localized:"… and \(items.count-50) more",bundle:.checkmate,comment:"Ends a list cut short; the number of entries not shown"):"")}.joined(separator:"\n\n")
    }
}
public enum LegacyImporter {
    private static let keys:Set<String>=["checkmate-practice-pgn","checkmate-previous-game","checkmate-settings-v1","checkmate-companion-preferences-v1","checkmate-course-v1","checkmate-puzzles-v1","checkmate-progress","spikeFEN"]
    private static func name(_ value:String)->String {String(value.prefix(80)).filter{!$0.isNewline && !$0.isASCIIControl}}
    private static func integer(_ value:Any?)->Int? {guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,floor(n.doubleValue)==n.doubleValue,abs(n.doubleValue)<Double(Int.max) else{return nil};return n.intValue}
    private static func boolean(_ value:Any?)->Bool? {guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else{return nil};return n.boolValue}
    private static func settingsReport(_ raw:[String:Any],normalized:AppSettings,report:inout ImportReport)throws {
        let output=try JSONSerialization.jsonObject(with:JSONEncoder().encode(normalized)) as! [String:Any]
        for (key,value) in raw.sorted(by:{$0.key<$1.key}) {
            let label=String(localized:"Setting: \(name(key))",bundle:.checkmate)
            guard let result=output[key] else{report.ignored.append(label);continue}
            let a=try? JSONSerialization.data(withJSONObject:["v":value],options:.sortedKeys),b=try JSONSerialization.data(withJSONObject:["v":result],options:.sortedKeys)
            if a==b {report.recovered.append(label)}else{report.adjusted.append(label)}
        }
    }
    private static func normalizeNativeLearning(_ value:inout ApplicationState,course:CourseLibrary,report:inout ImportReport){
        if !course.lessons.contains(where:{$0.id==value.course.lessonID}){value.course.lessonID=course.lessons[0].id;value.course.step=0;value.course.segmentID=nil;report.adjusted.append(String(localized:"Current lesson",bundle:.checkmate))}
        let lesson=course.lessons.first{$0.id==value.course.lessonID}!
        let step=course.resumeStep(in:lesson,progress:value.course)
        if step != value.course.step{report.adjusted.append(String(localized:"Lesson transcript",bundle:.checkmate))}
        value.course.step=step;value.course.segmentID=lesson.beats[step].id
        value.course.completed=value.course.completed.filter{id in let valid=course.lessons.contains{$0.id==id};if !valid{report.ignored.append(String(localized:"Invalid completed lesson",bundle:.checkmate))};return valid}
        value.course.answered=value.course.answered.filter{id in let valid=course.knownAnswerID(id);if !valid{report.ignored.append(String(localized:"Invalid answered exercise",bundle:.checkmate))};return valid}
        let known=Set(course.puzzles.map(\.id));value.puzzles=value.puzzles.filter{id,_ in if !known.contains(id){report.ignored.append(String(localized:"Puzzle progress: \(name(id))",bundle:.checkmate));return false};return true}
        for id in value.puzzles.keys where value.puzzles[id]!.attempts<0{value.puzzles[id]!.attempts=0;report.adjusted.append(String(localized:"Puzzle attempts: \(name(id))",bundle:.checkmate))}
    }
    @discardableResult public static func apply(_ data:Data,to target:inout ApplicationState,course:CourseLibrary)throws -> ImportReport {
        guard data.count<=StateStore.maximumBytes,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw CheckmateError.invalid(String(localized:"Invalid progress archive.",bundle:.checkmate))}
        var report=ImportReport()
        let hash=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        if target.importedArchives.contains(hash){report.duplicate=true;return report}
        if root["schemaVersion"] != nil {
            guard integer(root["schemaVersion"])==1 else{throw CheckmateError.invalid(String(localized:"Unsupported archive version. Your current progress has not changed.",bundle:.checkmate))}
            var imported=try JSONDecoder().decode(ApplicationState.self,from:data);normalizeNativeLearning(&imported,course:course,report:&report);try StateStore.validate(imported)
            // Every field the imported state carries was recovered; deriving the list from it keeps the report true as
            // fields are added (mini-games were imported but reported as skipped).
            let supported=Set((try JSONSerialization.jsonObject(with:JSONEncoder().encode(imported)) as? [String:Any] ?? [:]).keys)
            // Decoding keeps only the mini-games this version knows; the rest are skipped, and none kept is none recovered.
            let games=(root["miniGames"] as? [String:Any])?.keys.sorted() ?? [],dropped=games.filter{imported.miniGames?[$0]==nil}
            report.recovered=root.keys.filter{supported.contains($0) && $0 != "settings" && ($0 != "miniGames" || games.isEmpty || dropped.count<games.count)}.sorted().map{name($0)}
            report.ignored += root.keys.filter{!supported.contains($0)}.sorted().map{name($0)}+dropped.map{String(localized:"Mini-game: \(name($0))",bundle:.checkmate)}
            if let raw=root["settings"] as? [String:Any]{try settingsReport(raw,normalized:imported.settings,report:&report)}
            imported.importedArchives=Array(Set(imported.importedArchives+target.importedArchives+[hash])).sorted();target=imported;return report
        }
        let archive=(root["values"] as? [String:Any]) ?? root
        guard !keys.intersection(archive.keys).isEmpty else{throw CheckmateError.invalid(String(localized:"This file contains no Checkmate progress.",bundle:.checkmate))}
        report.ignored=archive.keys.filter{!keys.contains($0)}.sorted().map{name($0)}
        func value(_ key:String)->Any? {guard let raw=archive[key] else{return nil};if let text=raw as? String,let data=text.data(using:.utf8),let parsed=try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed){return parsed};return raw}
        var next=target,importedPractice=false,importedPrevious=false
        for (key,label) in [("spikeFEN",String(localized:"Practice position (history unavailable)",bundle:.checkmate)),("checkmate-practice-pgn",String(localized:"Practice game",bundle:.checkmate)),("checkmate-previous-game",String(localized:"Previous game",bundle:.checkmate))] {
            guard let raw=value(key) else{continue};guard let text=raw as? String else{report.ignored.append(label);continue}
            let rules=key=="spikeFEN" ? try ChessRules(fen:text):try ChessRules()
            if key != "spikeFEN"{try rules.restore(text)}
            if key=="checkmate-previous-game"{importedPrevious=true;next.practice.previousGame=text;next.practice.previousSide="w";next.practice.previousEnding=nil;next.practice.previousStartPly=0;next.practice.previousHints=0}else{next.practice.pgn=rules.pgn;next.practice.fen=rules.fen;next.practice.ending=nil;next.practice.startPly=0;next.practice.hints=0;next.practice.beginnerSevereStreak=0;importedPractice=true}
            report.recovered.append(label)
        }
        // The replaced game stays one step away under Restore Previous Game unless the archive brings its own.
        if importedPractice,!importedPrevious,!target.practice.pgn.isEmpty{next.practice.previousGame=target.practice.pgn;next.practice.previousSide=target.settings.practiceSide;next.practice.previousEnding=target.practice.ending;next.practice.previousStartPly=target.practice.startPly;next.practice.previousHints=target.practice.hints}
        // Only the settings the archive carries change; everything it lacks keeps its current value, so an old archive
        // never silently re-enables voice auto-connect, the microphone or MCP, or resets opponent strength.
        if let raw=value("checkmate-settings-v1") {if let settings=raw as? [String:Any]{let current=(try? JSONSerialization.jsonObject(with:JSONEncoder().encode(target.settings)) as? [String:Any]) ?? [:];next.settings=AppSettings(raw:current.merging(settings){_,imported in imported});try settingsReport(settings,normalized:next.settings,report:&report)}else{report.ignored.append(String(localized:"Settings",bundle:.checkmate))}}
        if let raw=value("checkmate-companion-preferences-v1") {
            if let dictionary=raw as? [String:Any],let role=dictionary["role"] as? String,["coach","opponent"].contains(role){next.settings.companionRole=role;report.recovered.append(String(localized:"Companion role",bundle:.checkmate))}else{report.ignored.append(String(localized:"Companion role",bundle:.checkmate))}
        }
        if let raw=value("checkmate-course-v1") {
            if let p=raw as? [String:Any] {
                let index=integer(p["lesson"]).flatMap{course.lessons.indices.contains($0) ? $0:nil} ?? 0,lesson=course.lessons[index]
                next.course.lessonID=lesson.id
                if integer(p["lesson"]) != index{report.adjusted.append(String(localized:"Current lesson",bundle:.checkmate))}else{report.recovered.append(String(localized:"Current lesson",bundle:.checkmate))}
                var oldProgress=CourseProgress();oldProgress.step=integer(p["step"]) ?? 0
                next.course.step=course.resumeStep(in:lesson,progress:oldProgress);next.course.segmentID=lesson.beats[next.course.step].id
                if integer(p["step"]) != next.course.step{report.adjusted.append(String(localized:"Lesson transcript",bundle:.checkmate))}else{report.recovered.append(String(localized:"Lesson transcript",bundle:.checkmate))}
                func entries(_ key:String,_ accepts:(String)->Bool)->[String] {
                    guard let values=p[key] as? [Any] else{if p[key] != nil{report.ignored.append(String(localized:"Course \(key)",bundle:.checkmate))};return []}
                    var accepted:[String]=[]
                    for entry in values {if let id=entry as? String,accepts(id){accepted.append(id);report.recovered.append(String(localized:"Course \(key): \(name(id))",bundle:.checkmate))}else{report.ignored.append(String(localized:"Invalid course \(key) entry",bundle:.checkmate))}}
                    return Array(Set(accepted)).sorted()
                }
                next.course.completed=entries("completed"){id in course.lessons.contains{$0.id==id}}
                next.course.answered=entries("answered"){course.knownAnswerID($0)}
            }else{report.ignored.append(String(localized:"Course progress",bundle:.checkmate))}
        }
        if let raw=value("checkmate-puzzles-v1") {
            if let puzzles=raw as? [String:Any] {
                let known=Set(course.puzzles.map(\.id))
                for (id,value) in puzzles.sorted(by:{$0.key<$1.key}) {
                    let label=String(localized:"Puzzle progress: \(name(id))",bundle:.checkmate)
                    guard known.contains(id),let record=value as? [String:Any],let solved=boolean(record["solved"]),let review=boolean(record["review"]),let attempts=integer(record["attempts"]),attempts>=0 else{report.ignored.append(label);continue}
                    var progress=PuzzleProgress();progress.solved=solved;progress.review=review;progress.attempts=attempts;next.puzzles[id]=progress;report.recovered.append(label)
                }
            }else{report.ignored.append(String(localized:"Puzzle progress",bundle:.checkmate))}
        }
        if let raw=value("checkmate-progress") {
            if let ids=raw as? [Any] {for value in ids {guard let id=value as? String,course.puzzles.contains(where:{$0.id==id}) else{report.ignored.append(String(localized:"Invalid legacy puzzle entry",bundle:.checkmate));continue};if next.puzzles[id]==nil{var progress=PuzzleProgress();progress.solved=true;next.puzzles[id]=progress};report.recovered.append(String(localized:"Legacy puzzle: \(name(id))",bundle:.checkmate))}}else{report.ignored.append(String(localized:"Legacy puzzle progress",bundle:.checkmate))}
        }
        // Legacy practice games were always played as White, whatever the settings say.
        if importedPractice{next.settings.practiceSide="w"}
        try StateStore.validate(next);next.importedArchives.append(hash);target=next;return report
    }
}
private extension Character {var isASCIIControl:Bool {unicodeScalars.contains{$0.value<32 || $0.value==127}}}
