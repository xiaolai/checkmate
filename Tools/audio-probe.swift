import Foundation
import AVFoundation

// Decode and inspect recordings without starting audio playback or audio input.
let paths = try JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
var results: [[String: Any]] = []
for path in paths {
    let value: [String: Any] = try autoreleasepool {
        let url = URL(fileURLWithPath: path)
        let file = try AVAudioFile(forReading: url)
        let player = try AVAudioPlayer(contentsOf: url)
        guard file.length > 0, player.duration.isFinite, player.duration > 0 else {
            throw NSError(domain: "AudioProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty audio: \(path)"])
        }
        let capacity: AVAudioFrameCount = 4096
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity)!
        var decoded: Int64 = 0, peak: Float = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: capacity)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                throw NSError(domain: "AudioProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Decode failed: \(path)"])
            }
            for channel in 0..<Int(buffer.format.channelCount) {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channels[channel][i])) }
            }
            decoded += Int64(buffer.frameLength)
        }
        guard decoded == file.length, peak > 0 else {
            throw NSError(domain: "AudioProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Silent or incomplete audio: \(path)"])
        }
        return ["file": path, "seconds": player.duration, "frames": decoded,
                "sampleRate": file.processingFormat.sampleRate, "channels": file.processingFormat.channelCount,
                "peak": peak]
    }
    results.append(value)
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]))
