import CheckmateAssets
import Foundation
/// `narrationFailure` is why the last `play` could not start (nil when it played or was muted by the settings).
@MainActor public protocol NarrationService:AnyObject {func play(file:String,seconds:Double,settings:AppSettings);func play(localURL:URL,seconds:Double,settings:AppSettings);func pause();func stop();var playbackTime:Double? {get};var narrationFailure:String? {get};func setNarrationVolume(_ volume:Double)}
public extension NarrationService {func play(localURL:URL,seconds:Double,settings:AppSettings){};var playbackTime:Double? {nil};var narrationFailure:String? {nil};func setNarrationVolume(_ volume:Double){}}
