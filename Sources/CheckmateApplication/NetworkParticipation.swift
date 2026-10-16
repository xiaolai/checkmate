import CheckmateDomain
import Foundation
/// Whether the learner is in a network game, seated or watching (LAN-play plan D8). It is set from `seated` or
/// `watching` and cleared by `ended`, Leave, or a connection given up; nothing else writes it.
@MainActor public final class NetworkParticipation:ObservableObject {
    public enum Role:String {case player,spectator}
    @Published public private(set) var role:Role?
    /// Advances on every change, so work started under one participation state can tell it changed under it, and a
    /// waiting agent is woken whatever its event filter (D15).
    public private(set) var epoch=0
    private var observers:[(Role?)->Void]=[]
    public init(){}
    /// Runs on every change, after `role` has its new value: the app cancels engine and voice work on joining here.
    public func observe(_ handler:@escaping (Role?)->Void){observers.append(handler)}
    public func begin(_ role:Role){guard self.role != role else{return};self.role=role;changed()}
    public func end(){guard role != nil else{return};role=nil;changed()}
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
    /// The error code MCP tools and refused calls carry while participating (D15).
    public static let refusal="NETWORK_GAME"
    public static let practicePaused="Paused during your network game"
    public static let analysisHidden="Analysis is hidden during your network game"
    public static let destinationUnavailable="Finish your network game first"
}
