import CheckmateDomain
import CheckmateSupport
import CheckmateAssets
import Foundation
import AVFoundation
public struct AudioPolicy {public let automation:Bool;public init(automation:Bool){self.automation=automation};public func mayPlay(enabled:Bool,volume:Double)->Bool {!automation && enabled && volume>0}
    /// Whether the learner's settings let narration (lessons and the Settings preview) be heard at all.
    public static func narrationAudible(_ settings:AppSettings)->Bool {settings.narration && settings.volume>0}}
@MainActor public final class NativeAudio:NarrationService {
    public let policy:AudioPolicy
    private var narration:AVAudioPlayer?,effect:AVAudioPlayer?
    private let scores:[String:[Tone]]
    public private(set) var error:String?
    public private(set) var narrationFailure:String?
    public static let playbackFailure="Narration could not play. You can still read the transcript."
    public static let replacedFailure="Checkmate was updated or moved while open, so lesson narration is unavailable. Quit and reopen Checkmate to hear it."
    /// Bundled narration resolves by path into the app bundle on disk. An update installed (or a move made) while the app
    /// runs leaves this process's course pointing at files that are gone; only a relaunch loads the new course.
    private let bundleURL:URL,launchedBundle:String?
    public init(automation:Bool=NativePolicy.silent,scores:[String:[Tone]],bundleURL:URL=Bundle.main.bundleURL){policy=AudioPolicy(automation:automation);self.scores=scores;self.bundleURL=bundleURL;launchedBundle=Self.bundleIdentity(bundleURL)}
    /// The file identity of the bundle's Info.plist (replaced with every install); nil outside an app bundle.
    static func bundleIdentity(_ bundle:URL)->String? {guard let attributes=try? FileManager.default.attributesOfItem(atPath:bundle.appendingPathComponent("Contents/Info.plist").path),let inode=attributes[.systemFileNumber] as? NSNumber,let modified=attributes[.modificationDate] as? Date else{return nil};return "\(inode)|\(modified.timeIntervalSince1970)"}
    /// Why bundled narration failed: the generic message, or a relaunch request when the app on disk is not this one.
    var bundledNarrationFailure:String {Self.bundleIdentity(bundleURL)==launchedBundle ? Self.playbackFailure:Self.replacedFailure}
    public func play(file:String,seconds:Double,settings:AppSettings){stop();narrationFailure=nil;guard policy.mayPlay(enabled:settings.narration,volume:settings.volume) else{return};do{let p=try AVAudioPlayer(contentsOf:NativeResources.url(file));p.volume=Float(settings.volume);p.currentTime=min(seconds,p.duration);guard p.play() else{throw CheckmateError.unavailable("Narration could not play.")};narration=p}catch{narrationFailure=bundledNarrationFailure}}
    public func play(localURL:URL,seconds:Double,settings:AppSettings){stop();narrationFailure=nil;guard localURL.isFileURL,policy.mayPlay(enabled:settings.narration,volume:settings.volume) else{return};do{let values=try localURL.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey]);guard values.isSymbolicLink != true,(values.fileSize ?? Int.max)<=28_800_044 else{throw CheckmateError.invalid("Invalid local recording.")};let p=try AVAudioPlayer(contentsOf:localURL);p.volume=Float(settings.volume);p.currentTime=min(seconds,p.duration);guard p.play() else{throw CheckmateError.unavailable("Narration could not play.")};narration=p}catch{narrationFailure=Self.playbackFailure}}
    public func setNarrationVolume(_ volume:Double){narration?.volume=Float(volume)}
    public var isNarrationPlaying:Bool {narration?.isPlaying==true}
    public var playbackTime:Double? {guard let narration=narration,narration.isPlaying else{return nil};return narration.currentTime}
    public func pause(){narration?.pause()}
    public func stop(){narration?.stop();narration=nil}
    public func illustration(piece:String,capture:Bool,settings:AppSettings){guard policy.mayPlay(enabled:settings.moveSounds,volume:settings.effectsVolume) else{return};var tones=scores[piece] ?? [];if capture{tones.append(Tone(at:0,duration:0.045,from:1050,to:170,gain:0.055,wave:"triangle"))};do{let player=try AVAudioPlayer(data:Self.wave(tones));player.volume=Float(settings.effectsVolume*(narration?.isPlaying==true ? 0.35:1));player.play();effect=player}catch{self.error="Move sound could not play."}}
    public func stopAll(){stop();effect?.stop();effect=nil}
    public func move(_ move:MoveRecord?,settings:AppSettings,undo:Bool=false){guard policy.mayPlay(enabled:settings.moveSounds,volume:settings.effectsVolume) else{return};var tones:[Tone]=[],at=0.0
        func piece(_ type:String,_ time:Double){for t in scores[type] ?? [] {tones.append(Tone(at:time+t.at,duration:t.duration,from:t.from,to:t.to,gain:t.gain,wave:t.wave))}}
        if undo{tones=[Tone(at:0,duration:0.065,from:300,to:210,gain:0.055,wave:"sine")]}else if let m=move {
            if m.captured != nil {tones.append(Tone(at:0,duration:0.045,from:1050,to:170,gain:0.055,wave:"triangle"));at=0.035}
            if m.flags.contains("k") || m.flags.contains("q"){piece("k",at);piece("r",at+0.11)}else if m.promotion != nil{piece("p",at);tones.append(Tone(at:at+0.09,duration:0.12,from:550,to:550,gain:0.05,wave:"sine"));tones.append(Tone(at:at+0.2,duration:0.16,from:740,to:740,gain:0.045,wave:"sine"))}else{piece(m.piece,at)}
            let end=(tones.map{$0.at+$0.duration}.max() ?? 0)+0.035
            if m.san.contains("#"){for (i,f) in [520.0,650,780].enumerated(){tones.append(Tone(at:end+Double(i)*0.11,duration:i==2 ? 0.22:0.12,from:f,to:f,gain:0.04,wave:"sine"))}}else if m.san.contains("+"){tones.append(Tone(at:end,duration:0.12,from:740,to:740,gain:0.035,wave:"sine"))}
        }
        do{let p=try AVAudioPlayer(data:Self.wave(tones));p.volume=Float(settings.effectsVolume*(narration?.isPlaying==true ? 0.35:1));p.play();effect=p}catch{self.error="Move sound could not play."}
    }
    public static func wave(_ tones:[Tone])->Data {
        let rate=24000,count=Int(((tones.map{$0.at+$0.duration}.max() ?? 0)+0.01)*Double(rate));var samples=[Double](repeating:0,count:count)
        for t in tones {let start=Int(t.at*Double(rate)),n=Int(t.duration*Double(rate));var phase=0.0
            for i in 0..<n where start+i<count {let time=Double(i)/Double(rate),ratio=min(1,time/(t.duration*0.75)),frequency=t.from*pow(t.to/t.from,ratio);phase+=2*Double.pi*frequency/Double(rate);let envelope=time<0.004 ? time/0.004:pow(0.00001/max(t.gain,0.00001),(time-0.004)/max(0.001,t.duration-0.004));let value=t.wave=="triangle" ? 2/Double.pi*asin(sin(phase)):sin(phase);samples[start+i]+=value*t.gain*envelope}
        }
        var payload=Data();for x in samples {var value=Int16(max(-1,min(1,x))*32767).littleEndian;withUnsafeBytes(of:&value){payload.append(contentsOf:$0)}}
        var data=Data("RIFF".utf8)
        func append<T:FixedWidthInteger>(_ value:T){var v=value.littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
        append(UInt32(payload.count+36));data.append(Data("WAVEfmt ".utf8));append(UInt32(16));append(UInt16(1));append(UInt16(1));append(UInt32(rate));append(UInt32(rate*2));append(UInt16(2));append(UInt16(16));data.append(Data("data".utf8));append(UInt32(payload.count));data.append(payload);return data
    }
}
