import CheckmateDomain
import CheckmateSupport
import Foundation
public struct VoiceTurnGate {
    private var generating=false,playing=false,ended=false
    public init(){}
    public var ready:Bool{!generating && !playing}
    /// A response is still being generated (as opposed to only its audio still playing).
    public var generatingResponse:Bool{generating}
    public mutating func begin(){generating=true;ended=false}
    public mutating func generated(hasAudio:Bool){generating=false;if hasAudio && !ended{playing=true}}
    public mutating func playbackStarted(){playing=true}
    public mutating func playbackEnded(){playing=false;ended=true}
    public mutating func reset(){generating=false;playing=false;ended=false}
}
public enum VoicePCM {
    public static func encode(_ samples:[Float])->Data {var data=Data(capacity:samples.count*2);for v in samples{var n=Int16((v.isFinite ? max(-1,min(1,v)):0)*32767).littleEndian;withUnsafeBytes(of:&n){data.append(contentsOf:$0)}};return data}
    public static func decode(_ data:Data)->[Float]{stride(from:0,to:max(0,data.count-1),by:2).map{Float(Int16(bitPattern:UInt16(data[$0]) | UInt16(data[$0+1])<<8))/32768}}
}
public final class VoiceGateway:NSObject,URLSessionTaskDelegate,@unchecked Sendable {
    public static let credentialURL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
    /// The ChatGPT sign-in Codex keeps for this Mac, read and never written. Voice runs on the learner's ChatGPT
    /// subscription only: an API-key sign-in (and its key) is never used.
    public static func accessToken(_ data:Data)throws->String {
        guard data.count<=65536,let a=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw signedOut}
        if (a["auth_mode"] as? String)?.lowercased()=="apikey"{throw apiKeySignIn}
        guard let token=(a["tokens"] as? [String:Any])?["access_token"] as? String,!token.isEmpty,token.count<=65536 else{throw signedOut}
        return token
    }
    public static let signedOut=CheckmateError.unavailable("Sign in to Codex on this Mac with your ChatGPT account before connecting.")
    public static let apiKeySignIn=CheckmateError.unavailable("Voice uses your ChatGPT subscription. Codex on this Mac is signed in with an API key; sign in to Codex with ChatGPT, then connect again.")
    /// Codex can keep its sign-in in the keychain instead of this file; Checkmate reads only the file.
    public static let noSignInFile=CheckmateError.unavailable("Checkmate could not find Codex's sign-in file. Sign in to Codex on this Mac (with its sign-in stored in a file, not only in the keychain), then connect again.")
    public static func clientSecret(_ data:Data)throws->String {guard data.count<=65536,let a=try JSONSerialization.jsonObject(with:data) as? [String:Any],let t=a["value"] as? String,!t.isEmpty,t.count<=4096 else{throw CheckmateError.unavailable("The account did not provide a voice session credential.")};return t}
    /// The learner-facing reason a Codex access token cannot be used: it has expired (Codex refreshes it only while
    /// Codex runs, and Checkmate never refreshes it, which would invalidate Codex's own copy). Nil when it is usable
    /// or carries no readable expiry.
    public static func expiredSignIn(_ token:String,now:Date=Date())->CheckmateError? {
        let parts=token.split(separator:".");guard parts.count==3 else{return nil};var payload=String(parts[1]).replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/");payload+=String(repeating:"=",count:(4-payload.count%4)%4)
        guard let data=Data(base64Encoded:payload),let claims=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let expiry=(claims["exp"] as? NSNumber)?.doubleValue else{return nil}
        return expiry<=now.timeIntervalSince1970+60 ? Self.signInExpired:nil
    }
    public static let signInExpired=CheckmateError.unavailable("Your Codex sign-in has expired. Open Codex once to refresh it, then connect again.")
    /// A model the account cannot open a session for; the next candidate model is tried.
    public struct ModelUnsupported:Error {public let status:Int}
    /// What an HTTP status from the session credential request means for the learner. 400, 404 and 422 name the model
    /// as the problem, so selection moves on; every other failure is about the account or the service and stops it.
    public static func authorizationFailure(status:Int)->Error {
        switch status {
        case 400,404,422:return ModelUnsupported(status:status)
        case 401:return CheckmateError.unavailable("Your Codex sign-in was not accepted. Open Codex and sign in again, then connect.")
        case 403:return CheckmateError.unavailable("This account was refused access to live voice.")
        case 429:return CheckmateError.unavailable("Live voice is rate-limited for this account right now. Try again later.")
        case 500...599:return CheckmateError.unavailable("Live voice is temporarily unavailable. Try again shortly.")
        default:return CheckmateError.unavailable("The account could not authorize live voice. Check account access and connectivity.")
        }
    }
    public static let unreachable=CheckmateError.unavailable("Could not reach live voice. Check your internet connection.")
    public func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){completionHandler(nil)}
    public func authorize(model:String="gpt-realtime") async throws->String {
        guard !NativePolicy.silent else{throw CheckmateError.unavailable("Live voice is disabled during automation.")}
        guard FileManager.default.fileExists(atPath:Self.credentialURL.path) else{throw Self.noSignInFile};let attributes=try FileManager.default.attributesOfItem(atPath:Self.credentialURL.path);guard (attributes[.size] as? Int ?? Int.max)<=65536 else{throw CheckmateError.unavailable("The sign-in file is invalid.")};let token=try Self.accessToken(Data(contentsOf:Self.credentialURL));if let expired=Self.expiredSignIn(token){throw expired};var request=URLRequest(url:URL(string:"https://api.openai.com/v1/realtime/client_secrets")!);request.httpMethod="POST";request.timeoutInterval=20;request.setValue("Bearer \(token)",forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody=try JSONSerialization.data(withJSONObject:["session":["type":"realtime","model":model]])
        let configuration=URLSessionConfiguration.ephemeral;configuration.timeoutIntervalForResource=25;let session=URLSession(configuration:configuration,delegate:self,delegateQueue:nil);defer{session.invalidateAndCancel()};let data:Data,response:URLResponse
        do{(data,response)=try await session.data(for:request)}catch let error as URLError where error.code != .cancelled{throw Self.unreachable}
        guard let http=response as? HTTPURLResponse else{throw Self.unreachable};guard (200..<300).contains(http.statusCode) else{NativeLog.voice.error("Voice authorization failed with HTTP \(http.statusCode, privacy: .public)");throw Self.authorizationFailure(status:http.statusCode)};return try Self.clientSecret(data)
    }
}

/// One configuration shared by the app and explicit headless service acceptance.
public enum VoiceSessionConfiguration {
    public static let model="gpt-realtime-2.1"
    public static let socketURL=socketURL(model:model)
    public static func socketURL(model:String)->URL {URL(string:"wss://api.openai.com/v1/realtime?model=\(model)")!}
    public static func reasoningEvent(effort:String)->[String:Any] {
        ["type":"session.update","session":["type":"realtime","reasoning":["effort":AppSettings.reasoningEfforts.contains(effort) ? effort:"minimal"]]]
    }
    /// Low eagerness waits through a beginner's thinking pause instead of answering half a question.
    public static let eagerness="low"
    /// Transcription settings: a language hint only when the learner chose one (ISO-639-1, as the provider expects).
    public static func transcription(language:String?)->[String:Any] {var value:[String:Any]=["model":"gpt-4o-mini-transcribe"];if let language,!language.isEmpty{value["language"]=language};return value}
    public static func transcriptionEvent(language:String?)->[String:Any] {["type":"session.update","session":["type":"realtime","audio":["input":["transcription":transcription(language:language)]]]]}
    public static func event(instructions:String,voice:String,tools:[[String:Any]],effort:String="minimal",inputLanguage:String?=nil)->[String:Any] {
        ["type":"session.update","session":["type":"realtime","instructions":instructions,"reasoning":["effort":AppSettings.reasoningEfforts.contains(effort) ? effort:"minimal"],"output_modalities":["audio"],"audio":["input":["format":["type":"audio/pcm","rate":24000],"turn_detection":["type":"semantic_vad","eagerness":eagerness,"create_response":false,"interrupt_response":false],"transcription":transcription(language:inputLanguage),"noise_reduction":["type":"far_field"]],"output":["format":["type":"audio/pcm","rate":24000],"voice":voice]],"tools":tools,"tool_choice":"auto"]]
    }
}

public enum VoiceScriptRequest {
    public static func event(text:String,language:String,metadata:[String:String]=[:])->[String:Any] {
        ["type":"response.create","response":["conversation":"none","input":[],"output_modalities":["audio"],"tool_choice":"none","metadata":metadata,"instructions":"You are a text-to-speech reader. Read exactly the script below, in its written language. Do not greet, answer, explain, translate, or add words. The selected response language is \(language). SCRIPT:\n"+text]]
    }
    /// Exact match of the words and numbers spoken, ignoring case, punctuation and how a number is written: every
    /// Unicode digit counts as ASCII, and with the script's locale every number is spelled out on both sides, so
    /// "4", "٤" and "vier" match while a different number, a missing word or an added word never does.
    public static func matches(_ transcript:String,script:String,locale:String?=nil)->Bool {
        !script.isEmpty && canonical(transcript,locale:locale)==canonical(script,locale:locale)
    }
    static func canonical(_ value:String,locale:String?)->String {
        func ascii(_ value:String)->String {
            var text="";for character in value.precomposedStringWithCompatibilityMapping.lowercased() {
                if character.unicodeScalars.count==1,let scalar=character.unicodeScalars.first,scalar.properties.numericType == .decimal,let digit=character.wholeNumberValue{text.append(Character(String(digit)))}else{text.append(character)}
            }
            return text
        }
        var text=ascii(value)
        if let locale,!locale.isEmpty {
            // A number grouped as the locale groups it ("1,000", "1.000", "1 000", "1,00,000") is one number, written as
            // plain digits before spelling, so it matches "1000" and "one thousand" instead of becoming "one zero".
            let grouping=NumberFormatter();grouping.locale=Locale(identifier:locale);grouping.numberStyle = .decimal
            let separator=ascii(grouping.groupingSeparator),primary=grouping.groupingSize,secondary=grouping.secondaryGroupingSize>0 ? grouping.secondaryGroupingSize:grouping.groupingSize
            if !separator.isEmpty,primary>0,let regex=try? NSRegularExpression(pattern:"[0-9]+(?:"+NSRegularExpression.escapedPattern(for:separator)+"[0-9]+)+") {
                for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).reversed() {
                    guard let range=Range(match.range,in:text) else{continue};let groups=text[range].components(separatedBy:separator)
                    if groups.last!.count==primary,groups.dropFirst().dropLast().allSatisfy({$0.count==secondary}),(1...(groups.count>2 ? secondary:primary)).contains(groups[0].count){text.replaceSubrange(range,with:groups.joined())}
                }
            }
            let formatter=NumberFormatter();formatter.locale=Locale(identifier:locale);formatter.numberStyle = .spellOut
            var spelled="",run=""
            func flush(){if !run.isEmpty{spelled+=(run.count<=15 ? Int(run).flatMap{formatter.string(from:NSNumber(value:$0))}?.lowercased():nil) ?? run;run=""}}
            for character in text{if character.isASCII,character.isNumber{run.append(character)}else{flush();spelled.append(character)}};flush();text=spelled
        }
        return text.unicodeScalars.filter{CharacterSet.alphanumerics.contains($0)}.map(String.init).joined()
    }
}
