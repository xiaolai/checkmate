import Foundation

/// A 440 Hz tone long enough for `script` at the plausibility limit (and at least `seconds`), as 24 kHz mono PCM16:
/// fixtures save audible, plausible clips instead of silence.
public func plausibleLessonPCM(_ script:String,seconds:Double=0)->Data {
    let letters=script.unicodeScalars.filter{CharacterSet.letters.contains($0)}.count
    let samples=max(2400,Int(seconds*24000),Int(Double(letters)/25*24000)+1);var data=Data(capacity:samples*2)
    for i in 0..<samples{var v=Int16(8000*sin(Double(i)*2*Double.pi*440/24000)).littleEndian;withUnsafeBytes(of:&v){data.append(contentsOf:$0)}}
    return data
}
