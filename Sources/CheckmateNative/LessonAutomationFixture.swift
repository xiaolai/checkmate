import Foundation
import CheckmateCore

/// Available only through NativeModel's explicit automation AND fixture gate.
struct LessonAutomationTranslator:LessonTranslationProvider {
    func translate(source:LessonTranslation,locale:String,onUsage:@escaping @Sendable(String,String,UsageTokens?)->Void)async throws->TranslationResult {
        try await Task.sleep(for:.milliseconds(700))
        var text=source;text.title="French lesson: "+source.title
        text.teaches=source.teaches.map{"French lesson: "+$0}
        for index in text.beats.indices {
            text.beats[index].stepTitle="French lesson: "+text.beats[index].stepTitle
            text.beats[index].say="French lesson: "+text.beats[index].say
            text.beats[index].speak="French lesson: "+text.beats[index].speak
        }
        let id=UUID().uuidString,tokens=UsageTokens(input:100,output:200,total:300)
        onUsage(id,"automation-fixture",tokens)
        return TranslationResult(text:text,model:"automation-fixture",turnID:id,tokens:tokens)
    }
    func accountStatus()async throws->String {"Automation fixture account status; no provider contacted."}
}
struct LessonAutomationRecorder:LessonRecordingProvider {
    func record(script:String,locale:String,voice:String,onUsage:@escaping @Sendable(String,UsageTokens?)->Void)async throws->LessonRecordingResult {
        try await Task.sleep(for:.milliseconds(800))
        let id=UUID().uuidString,tokens=UsageTokens(input:20,output:30,total:50)
        onUsage(id,tokens)
        let letters=script.unicodeScalars.filter{CharacterSet.letters.contains($0)}.count,samples=max(2400,Int(Double(letters)/25*24000)+1)
        // A quiet tone long enough for the script: recordings must be plausible speech length and not silent.
        var pcm=Data(capacity:samples*2);for i in 0..<samples{var v=Int16(4000*sin(Double(i)*2*Double.pi*440/24000)).littleEndian;withUnsafeBytes(of:&v){pcm.append(contentsOf:$0)}}
        return LessonRecordingResult(pcm:pcm,transcript:script,responseID:id,tokens:tokens,model:"gpt-realtime")
    }
}
