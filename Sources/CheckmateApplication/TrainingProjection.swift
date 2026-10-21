import CheckmateAssets
import CheckmateDomain
/// What the training activity shows, as the app, agents and voice may read it (plan rule 12). It never carries
/// accepted answers, solution sets, hidden trees or scheduled replies (plan rule 6).
public struct TrainingProjection:Codable,Equatable {
    /// `library`, `exercise` (a new training task) or `legacy_game` (an existing mini-game opened from the library).
    public var view:String
    public var entryId:String?,title:String,objective:String?,ruleMode:String?,rules:[String]
    public var prompt:String?,pieces:Position?,turn:String?,learnerSide:String?
    /// The marked square of a movement or recognition task.
    public var target:String?
    /// The learner's own current selection and the visible move count; neither reveals an answer.
    public var selected:[String]?,movesUsed:Int?,moveBudget:Int?,choices:[String]?
    /// `active`, `correct`, `incorrect` (retry offered), `revealed`, `suspended` (a technical fault) or `finished`.
    public var status:String?,feedback:String?
    /// The attempt has recorded in-app help (hints, reveal, undo or an agent submission).
    public var assisted:Bool
    public var sessionRevision:Int,attemptId:String?
    /// Legacy mini-game outcome fields, with the same meaning as the lesson projection's.
    public var winner:String?,drawReason:String?
    public init(view:String,entryId:String?=nil,title:String,objective:String?=nil,ruleMode:String?=nil,rules:[String]=[],prompt:String?=nil,pieces:Position?=nil,turn:String?=nil,learnerSide:String?=nil,target:String?=nil,selected:[String]?=nil,movesUsed:Int?=nil,moveBudget:Int?=nil,choices:[String]?=nil,status:String?=nil,feedback:String?=nil,assisted:Bool=false,sessionRevision:Int=0,attemptId:String?=nil,winner:String?=nil,drawReason:String?=nil){
        self.view=view;self.entryId=entryId;self.title=title;self.objective=objective;self.ruleMode=ruleMode;self.rules=rules;self.prompt=prompt;self.pieces=pieces;self.turn=turn;self.learnerSide=learnerSide;self.target=target
        self.selected=selected;self.movesUsed=movesUsed;self.moveBudget=moveBudget;self.choices=choices;self.status=status;self.feedback=feedback;self.assisted=assisted;self.sessionRevision=sessionRevision;self.attemptId=attemptId;self.winner=winner;self.drawReason=drawReason
    }
    public static let library=TrainingProjection(view:"library",title:String(localized:"Training",bundle:.checkmate))
    /// The version of the read-only training projection; a client that does not know `mode: "training"` must be updated.
    public static let protocolVersion=1
}
