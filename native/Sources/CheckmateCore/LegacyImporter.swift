import Foundation
import CryptoKit
import CoreFoundation

public struct ImportReport:Codable,Equatable {
    public var recovered:[String]=[],ignored:[String]=[],adjusted:[String]=[]
    public var duplicate=false
    public init(){}
    public var summary:String {duplicate ? "This archive was already imported. Your newer progress is unchanged.":"Recovered \(recovered.count) fields or records. Adjusted \(adjusted.count). Skipped \(ignored.count)."}
    public var details:String {
        [("Recovered",recovered),("Adjusted to supported values",adjusted),("Skipped",ignored)].filter{!$0.1.isEmpty}.map{title,items in title+"\n"+items.prefix(50).map{"• "+$0}.joined(separator:"\n")+(items.count>50 ? "\n… and \(items.count-50) more":"")}.joined(separator:"\n\n")
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
            let label="Setting: "+name(key)
            guard let result=output[key] else{report.ignored.append(label);continue}
            let a=try? JSONSerialization.data(withJSONObject:["v":value],options:.sortedKeys),b=try JSONSerialization.data(withJSONObject:["v":result],options:.sortedKeys)
            if a==b {report.recovered.append(label)}else{report.adjusted.append(label)}
        }
    }
    private static func normalizeNativeLearning(_ value:inout ApplicationState,course:CourseLibrary,report:inout ImportReport){
        if !course.lessons.contains(where:{$0.id==value.course.lessonID}){value.course.lessonID=course.lessons[0].id;report.adjusted.append("Current lesson")}
        let lesson=course.lessons.first{$0.id==value.course.lessonID}!
        if !lesson.beats.indices.contains(value.course.step){value.course.step=0;report.adjusted.append("Lesson transcript")}
        value.course.completed=value.course.completed.filter{id in let valid=course.lessons.contains{$0.id==id};if !valid{report.ignored.append("Invalid completed lesson")};return valid}
        value.course.answered=value.course.answered.filter{id in let valid=course.exercises[id] != nil;if !valid{report.ignored.append("Invalid answered exercise")};return valid}
        let known=Set(course.puzzles.map(\.id));value.puzzles=value.puzzles.filter{id,_ in if !known.contains(id){report.ignored.append("Puzzle progress: "+name(id));return false};return true}
        for id in value.puzzles.keys where value.puzzles[id]!.attempts<0{value.puzzles[id]!.attempts=0;report.adjusted.append("Puzzle attempts: "+name(id))}
    }
    @discardableResult public static func apply(_ data:Data,to target:inout ApplicationState,course:CourseLibrary)throws -> ImportReport {
        guard data.count<=4*1024*1024,let root=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw CheckmateError.invalid("Invalid progress archive.")}
        var report=ImportReport()
        let hash=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        if target.importedArchives.contains(hash){report.duplicate=true;return report}
        if root["schemaVersion"] != nil {
            guard integer(root["schemaVersion"])==1 else{throw CheckmateError.invalid("Unsupported archive version. Your current progress has not changed.")}
            var imported=try JSONDecoder().decode(ApplicationState.self,from:data);normalizeNativeLearning(&imported,course:course,report:&report);try StateStore.validate(imported)
            let supported:Set<String>=["schemaVersion","savedAt","practice","course","settings","puzzles","window","importedArchives","puzzleFilters"]
            report.recovered=root.keys.filter{supported.contains($0) && $0 != "settings"}.sorted().map{name($0)}
            report.ignored += root.keys.filter{!supported.contains($0)}.sorted().map{name($0)}
            if let raw=root["settings"] as? [String:Any]{try settingsReport(raw,normalized:imported.settings,report:&report)}
            imported.importedArchives=Array(Set(imported.importedArchives+target.importedArchives+[hash])).sorted();target=imported;return report
        }
        let archive=(root["values"] as? [String:Any]) ?? root
        guard !keys.intersection(archive.keys).isEmpty else{throw CheckmateError.invalid("This file contains no Checkmate progress.")}
        report.ignored=archive.keys.filter{!keys.contains($0)}.sorted().map{name($0)}
        func value(_ key:String)->Any? {guard let raw=archive[key] else{return nil};if let text=raw as? String,let data=text.data(using:.utf8),let parsed=try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed){return parsed};return raw}
        var next=target
        for (key,label) in [("spikeFEN","Practice position (history unavailable)"),("checkmate-practice-pgn","Practice game"),("checkmate-previous-game","Previous game")] {
            guard let raw=value(key) else{continue};guard let text=raw as? String else{report.ignored.append(label);continue}
            let rules=key=="spikeFEN" ? try ChessRules(fen:text):try ChessRules()
            if key != "spikeFEN"{try rules.restore(text)}
            if key=="checkmate-previous-game"{next.practice.previousGame=text}else{next.practice.pgn=rules.pgn;next.practice.fen=rules.fen}
            report.recovered.append(label)
        }
        if let raw=value("checkmate-settings-v1") {if let settings=raw as? [String:Any]{next.settings=AppSettings(raw:settings);try settingsReport(settings,normalized:next.settings,report:&report)}else{report.ignored.append("Settings")}}
        if let raw=value("checkmate-companion-preferences-v1") {
            if let dictionary=raw as? [String:Any],let role=dictionary["role"] as? String,["coach","opponent"].contains(role){next.settings.companionRole=role;report.recovered.append("Companion role")}else{report.ignored.append("Companion role")}
        }
        if let raw=value("checkmate-course-v1") {
            if let p=raw as? [String:Any] {
                let index=integer(p["lesson"]).flatMap{course.lessons.indices.contains($0) ? $0:nil} ?? 0,lesson=course.lessons[index]
                next.course.lessonID=lesson.id
                if integer(p["lesson"]) != index{report.adjusted.append("Current lesson")}else{report.recovered.append("Current lesson")}
                next.course.step=integer(p["step"]).flatMap{lesson.beats.indices.contains($0) ? $0:nil} ?? 0
                if integer(p["step"]) != next.course.step{report.adjusted.append("Lesson transcript")}else{report.recovered.append("Lesson transcript")}
                func entries(_ key:String,_ accepts:(String)->Bool)->[String] {
                    guard let values=p[key] as? [Any] else{if p[key] != nil{report.ignored.append("Course "+key)};return []}
                    var accepted:[String]=[]
                    for entry in values {if let id=entry as? String,accepts(id){accepted.append(id);report.recovered.append("Course "+key+": "+name(id))}else{report.ignored.append("Invalid course "+key+" entry")}}
                    return Array(Set(accepted)).sorted()
                }
                next.course.completed=entries("completed"){id in course.lessons.contains{$0.id==id}}
                next.course.answered=entries("answered"){course.exercises[$0] != nil}
            }else{report.ignored.append("Course progress")}
        }
        if let raw=value("checkmate-puzzles-v1") {
            if let puzzles=raw as? [String:Any] {
                let known=Set(course.puzzles.map(\.id))
                for (id,value) in puzzles.sorted(by:{$0.key<$1.key}) {
                    let label="Puzzle progress: "+name(id)
                    guard known.contains(id),let record=value as? [String:Any],let solved=boolean(record["solved"]),let review=boolean(record["review"]),let attempts=integer(record["attempts"]),attempts>=0 else{report.ignored.append(label);continue}
                    var progress=PuzzleProgress();progress.solved=solved;progress.review=review;progress.attempts=attempts;next.puzzles[id]=progress;report.recovered.append(label)
                }
            }else{report.ignored.append("Puzzle progress")}
        }
        if let raw=value("checkmate-progress") {
            if let ids=raw as? [Any] {for value in ids {guard let id=value as? String,course.puzzles.contains(where:{$0.id==id}) else{report.ignored.append("Invalid legacy puzzle entry");continue};if next.puzzles[id]==nil{var progress=PuzzleProgress();progress.solved=true;next.puzzles[id]=progress};report.recovered.append("Legacy puzzle: "+name(id))}}else{report.ignored.append("Legacy puzzle progress")}
        }
        try StateStore.validate(next);next.importedArchives.append(hash);target=next;return report
    }
}
private extension Character {var isASCIIControl:Bool {unicodeScalars.contains{$0.value<32 || $0.value==127}}}
