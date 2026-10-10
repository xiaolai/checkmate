import Foundation
import AVFoundation
import CoreAudio
import Combine
public struct VoiceInputDevice:Identifiable {public let id:String,name:String}
@MainActor public final class VoiceAudio:ObservableObject {
    @Published public private(set) var level:Double=0
    public var onError:((String)->Void)?
    private var configurationObserver:NSObjectProtocol?,outputObserver:NSObjectProtocol?
    public var capturing:Bool{capture?.isRunning==true}
    private var capture:AVAudioEngine?,output:AVAudioEngine?,player:AVAudioPlayerNode?,converter:AVAudioConverter?
    private var queued=0,generation=UUID(),captureGeneration=UUID(),captureDevice=""
    public var onInput:((Data)->Void)?,onPlaybackStart:(()->Void)?,onPlaybackEnd:(()->Void)?
    public var listening=false
    public var volume:Float=1{didSet{player?.volume=volume}}
    public init(){}
    public static func devices()->[VoiceInputDevice] {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain),size:UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size)==noErr else{return []};var ids=[AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size);guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&ids)==noErr else{return []}
        return ids.compactMap{id in var streams=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:kAudioDevicePropertyScopeInput,mElement:kAudioObjectPropertyElementMain),bytes:UInt32=0;guard AudioObjectGetPropertyDataSize(id,&streams,0,nil,&bytes)==noErr,bytes>0 else{return nil};func text(_ selector:AudioObjectPropertySelector)->String?{var a=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain),value:CFString?;var n=UInt32(MemoryLayout<CFString?>.size);guard AudioObjectGetPropertyData(id,&a,0,nil,&n,&value)==noErr else{return nil};return value as String?};guard let uid=text(kAudioDevicePropertyDeviceUID),let name=text(kAudioObjectPropertyName) else{return nil};return VoiceInputDevice(id:uid,name:name)}
    }
    public func startCapture(device:String) async throws {
        guard !NativePolicy.silent else{return};if capture?.isRunning==true,captureDevice==device{return};stopCapture();let epoch=captureGeneration
        let allowed=await AVCaptureDevice.requestAccess(for:.audio);guard epoch==captureGeneration else{throw CancellationError()};guard allowed else{throw CheckmateError.unavailable("Allow Checkmate in System Settings → Privacy & Security → Microphone.")}
        let engine=AVAudioEngine(),input=engine.inputNode
        if !device.isEmpty {var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyTranslateUIDToDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain);var uid=device as CFString,varID=AudioDeviceID(0),size=UInt32(MemoryLayout<AudioDeviceID>.size);let result=withUnsafePointer(to:&uid){AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,UInt32(MemoryLayout<CFString>.size),$0,&size,&varID)};guard result==noErr,varID != 0,let unit=input.audioUnit,AudioUnitSetProperty(unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&varID,size)==noErr else{throw CheckmateError.unavailable("The selected microphone is unavailable. Choose another input device.")}}
        let format=input.outputFormat(forBus:0);guard format.sampleRate>0,format.channelCount>0,let target=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:24000,channels:1,interleaved:false),let conversion=AVAudioConverter(from:format,to:target) else{throw CheckmateError.unavailable("This microphone audio format is unavailable.")};converter=conversion
        input.installTap(onBus:0,bufferSize:2048,format:format){[weak self] buffer,_ in
            let capacity=AVAudioFrameCount(ceil(Double(buffer.frameLength)*24000/format.sampleRate)+16);guard let converted=AVAudioPCMBuffer(pcmFormat:target,frameCapacity:capacity) else{return};var supplied=false,error:NSError?;conversion.convert(to:converted,error:&error){_,status in if supplied{status.pointee = .noDataNow;return nil};supplied=true;status.pointee = .haveData;return buffer};guard error==nil,let samples=converted.floatChannelData?[0] else{return};let data=VoicePCM.encode(Array(UnsafeBufferPointer(start:samples,count:Int(converted.frameLength))));Task{@MainActor in guard let self=self,self.listening,self.captureGeneration==epoch else{return};let samples=VoicePCM.decode(data);self.level=min(1,sqrt(samples.reduce(0){$0+Double($1*$1)}/Double(max(1,samples.count)))*4);self.onInput?(data)}
        };capture=engine;captureDevice=device;try engine.start();configurationObserver=NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:engine,queue:.main){[weak self] _ in Task{@MainActor in guard let self=self,self.captureGeneration==epoch else{return};self.stopCapture();self.onError?("Microphone configuration changed. Reconnect or select an available device.")}}
    }
    public func stopCapture(){captureGeneration=UUID();level=0;if let observer=configurationObserver{NotificationCenter.default.removeObserver(observer)};configurationObserver=nil;listening=false;capture?.inputNode.removeTap(onBus:0);capture?.stop();capture=nil;converter=nil}
    public func append(_ data:Data)throws {
        guard !NativePolicy.silent else{return};if output==nil {let e=AVAudioEngine(),p=AVAudioPlayerNode();e.attach(p);e.connect(p,to:e.mainMixerNode,format:AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:24000,channels:1,interleaved:false)!);try e.start();p.volume=volume;p.play();output=e;player=p;let epoch=generation;outputObserver=NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:e,queue:.main){[weak self] _ in Task{@MainActor in guard let self=self,self.generation==epoch else{return};self.stopOutput();self.onError?("Audio output changed. Reconnect the coach to continue.")}}}
        let values=VoicePCM.decode(data);guard !values.isEmpty,let buffer=AVAudioPCMBuffer(pcmFormat:player!.outputFormat(forBus:0),frameCapacity:AVAudioFrameCount(values.count)),let channel=buffer.floatChannelData?[0] else{return};buffer.frameLength=AVAudioFrameCount(values.count);values.withUnsafeBufferPointer{channel.update(from:$0.baseAddress!,count:values.count)};let epoch=generation;if queued==0{onPlaybackStart?()};queued+=1
        player!.scheduleBuffer(buffer,completionCallbackType:.dataPlayedBack){[weak self] _ in Task{@MainActor in guard let self=self,self.generation==epoch else{return};self.queued-=1;if self.queued==0{self.onPlaybackEnd?()}}}
    }
    public var playing:Bool{queued>0}
    public func stopOutput(){if let observer=outputObserver{NotificationCenter.default.removeObserver(observer)};outputObserver=nil;generation=UUID();player?.stop();output?.stop();player=nil;output=nil;queued=0}
    public func stop(){stopCapture();stopOutput()}
}
