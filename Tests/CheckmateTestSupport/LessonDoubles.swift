import Foundation
import CheckmateDomain
import CheckmateContent

/// Translates every lesson except those listed in `failing`, recording the order lessons were attempted.
public actor OrderedLessonTranslator:LessonTranslationProvider {
 public var failing:Set<String>,order:[String]=[];public init(failing:Set<String>=[]){self.failing=failing}
 public func fail(_ ids:Set<String>){failing=ids}
 public func translate(source:LessonTranslation,locale:String,onUsage:@escaping @Sendable(String,String,UsageTokens?)->Void)async throws->TranslationResult {order.append(source.lessonID);if failing.contains(source.lessonID){throw CheckmateError.invalid("The translation did not keep the chess notation.")};var text=source;text.title="Titre: "+source.title;return TranslationResult(text:text,model:"fake",turnID:UUID().uuidString,tokens:UsageTokens(total:3))}
 public func accountStatus()async throws->String {"Fake account"}
}
/// Records every clip except the scripts listed in `failing` (or every clip when `failAll`), in call order.
public actor OrderedLessonRecorder:LessonRecordingProvider {
 public var failing:Set<String>,failAll:Bool,scripts:[String]=[];public init(failing:Set<String>=[],failAll:Bool=false){self.failing=failing;self.failAll=failAll}
 public func fail(_ value:Set<String>){failing=value}
 public func record(script:String,locale:String,voice:String,onUsage:@escaping @Sendable(String,UsageTokens?)->Void)async throws->LessonRecordingResult {scripts.append(script);if failAll || failing.contains(script){throw CheckmateError.invalid("The recording did not match the requested script.")};return LessonRecordingResult(pcm:plausibleLessonPCM(script),transcript:script,responseID:UUID().uuidString,tokens:nil,model:"gpt-realtime")}
}
/// A French lesson controller storing its packs and usage under `directory`.
@MainActor public func lessonController(_ directory:URL,_ library:CourseLibrary,_ translator:any LessonTranslationProvider,_ recorder:any LessonRecordingProvider=OrderedLessonRecorder())throws -> LessonLanguageController {let c=try LessonLanguageController(library:library,directory:directory,usage:UsageLedger(directory:directory.appendingPathComponent("Usage")),translator:translator,recorder:recorder);c.language="fr";return c}
