import CheckmateDomain
import Foundation
/// Whether the learner is in a network game, seated or watching (LAN-play plan D8). It is set from `seated` or
/// `watching` and cleared by `ended`, Leave, or a connection given up; nothing else writes it.
@MainActor public final class NetworkParticipation:ObservableObject {
    public enum Role:String {case player,spectator}
    @Published public private(set) var role:Role?
    /// The assistance this Mac's player may use (assistance plan A1, A8): their own side's level from terms the game
    /// verified (A3). Always `off` for a spectator and outside a game.
    @Published public private(set) var assistance:NetworkAssistanceLevel = .off
    /// Advances on every change, so work started under one participation state can tell it changed under it, and a
    /// waiting agent is woken whatever its event filter (D15).
    public private(set) var epoch=0
    private var observers:[(Role?)->Void]=[]
    public init(){}
    /// Runs on every change, after `role` has its new value: the app cancels engine and voice work on joining here.
    public func observe(_ handler:@escaping (Role?)->Void){observers.append(handler)}
    /// Only the network game calls this, with the level its verified terms give the learner's side (A8).
    public func begin(_ role:Role,assistance:NetworkAssistanceLevel = .off){
        let level=role == .player ? assistance:.off
        guard self.role != role || self.assistance != level else{return};self.role=role;self.assistance=level;changed()
    }
    public func end(){guard role != nil else{return};role=nil;assistance = .off;changed()}
    private func changed(){epoch+=1;for observer in observers{observer(role)}}
}
/// The one check every engine and voice entry point asks (D8): no engine help, cached evidence or voice coaching while
/// the learner plays or watches a network game. Checked when work starts and again when its result arrives, after
/// every `await`, so work begun before joining delivers nothing.
@MainActor public final class FairnessPolicy {
    public let participation:NetworkParticipation
    /// A policy with its own participation, which nothing begins: for components built outside the app, such as tests.
    /// The app builds one and hands that same policy to every component (NativeModel).
    public init(participation:NetworkParticipation?=nil){self.participation=participation ?? NetworkParticipation()}
    public var engineHelpAllowed:Bool {participation.role==nil}
    /// Refuses engine or voice work while participating.
    public func requireEngineHelp()throws {guard engineHelpAllowed else{throw CheckmateError.invalid(Self.refusal)}}
    /// What the learner's own network game may show them (assistance plan A8). A scoped permission, not a lifted ban:
    /// `engineHelpAllowed` stays false throughout, so practice, Review, lessons, training and MCP stay closed at every
    /// level. Only the network game's own hints (`NetworkAssistant`) and inspector read this.
    public var networkAssistance:NetworkAssistanceLevel {participation.role == .player ? participation.assistance:.off}
    /// Refuses a network hint unless the learner's agreed level allows hints (A8).
    public func requireNetworkHint()throws {guard networkAssistance >= .hints else{throw CheckmateError.invalid(Self.refusal)}}
    /// Whether a voice-coach session may act (A10, amending D8). A session opened for practice (`network` false) acts
    /// only outside a network game, as D8 says; one opened for the learner's network game acts only while they play it
    /// at `hints` or `guided`. Each kind ends when the other's condition starts, so neither carries into the other.
    public func voiceAllowed(network:Bool)->Bool {network ? networkAssistance >= .hints:engineHelpAllowed}
    /// The error code MCP tools and refused calls carry while participating (D15).
    public static let refusal="NETWORK_GAME"
    public static let practicePaused="Paused during your network game"
    public static let analysisHidden="Analysis is hidden during your network game"
    public static let destinationUnavailable="Finish your network game first"
}
