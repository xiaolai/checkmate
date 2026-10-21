import SwiftUI
import CheckmateCore
/// Plain labels for how an entry's moves are judged, shown with every entry and exercise (plan rule 2).
enum TrainingLabels {
    static func ruleMode(_ mode:TrainingRuleMode)->String {switch mode {
        case .movementDrill:return String(localized:"Movement practice · only the marked piece moves",bundle:.checkmate)
        case .simplifiedVariant:return String(localized:"Simplified game · its own rules, not full chess",bundle:.checkmate)
        case .recognitionDiagram:return String(localized:"Diagram · reading attacks, not a game position",bundle:.checkmate)
        case .standardChess:return String(localized:"Standard chess rules",bundle:.checkmate)
    }}
    /// A subskill's button title.
    static func variant(_ id:String)->String {
        let names=["move-away":String(localized:"Move it away",bundle:.checkmate),"protect":String(localized:"Protect it",bundle:.checkmate),"capture-attacker":String(localized:"Capture the attacker",bundle:.checkmate),"block":String(localized:"Block the line",bundle:.checkmate),"mixed-method":String(localized:"Any defense",bundle:.checkmate),"free-piece":String(localized:"Free pieces",bundle:.checkmate),"poisoned-capture":String(localized:"Poisoned captures",bundle:.checkmate),"compare-exchange":String(localized:"Compare trades",bundle:.checkmate),"anticipate-recapture":String(localized:"Expect the recapture",bundle:.checkmate),"castle-legal":String(localized:"Castling",bundle:.checkmate),"castle-unavailable":String(localized:"When castling is not allowed",bundle:.checkmate),"promotion":String(localized:"Promotion",bundle:.checkmate),"en-passant-available":String(localized:"En passant",bundle:.checkmate),"en-passant-unavailable":String(localized:"When en passant is not allowed",bundle:.checkmate),"fork-recognize":String(localized:"Spot forks",bundle:.checkmate),"pin-recognize":String(localized:"Spot pins",bundle:.checkmate),"fork-realize":String(localized:"Win with a fork",bundle:.checkmate),"pin-realize":String(localized:"Win with a pin",bundle:.checkmate),"mate-threat-create":String(localized:"Threaten mate",bundle:.checkmate),"mate-threat-prevent":String(localized:"Stop a mate threat",bundle:.checkmate),"kqk":String(localized:"King and queen",bundle:.checkmate),"krk":String(localized:"King and rook",bundle:.checkmate),"mixed":String(localized:"Mixed",bundle:.checkmate),"kpk":String(localized:"King and pawn",bundle:.checkmate),"kbbk":String(localized:"Two bishops",bundle:.checkmate),"pawns":String(localized:"Pawns",bundle:.checkmate),"knights":String(localized:"Knights",bundle:.checkmate),"bishops":String(localized:"Bishops",bundle:.checkmate),"rooks":String(localized:"Rooks",bundle:.checkmate),"queens":String(localized:"Queens",bundle:.checkmate),"minor-pieces":String(localized:"Minor pieces",bundle:.checkmate),"major-pieces":String(localized:"Major pieces",bundle:.checkmate)]
        return names[id] ?? id.replacingOccurrences(of:"-",with:" ").capitalized
    }
    /// What a mixed case practised, shown only after the learner has answered.
    static func skill(_ skill:TrainingSkill)->String {switch skill {
        case .movement:return String(localized:"how the pieces move",bundle:.checkmate)
        case .attackProtection:return String(localized:"attack and protection",bundle:.checkmate)
        case .threatResponse:return String(localized:"answering a threat",bundle:.checkmate)
        case .captureExchange:return String(localized:"captures and trades",bundle:.checkmate)
        case .checkMateDraw:return "check, mate and draws"
        case .specialRules:return "castling, promotion and en passant"
        case .elementaryTactics:return "forks, pins and mating threats"
        case .convertingWin:return String(localized:"finishing a won game",bundle:.checkmate)
        case .gameHabits:return "game habits"
        case .diagnosis:return String(localized:"spotting what matters",bundle:.checkmate)
    }}
}
/// Buttons laid out three to a row, eagerly: a lazy grid leaves rows below the fold out of the accessibility tree.
struct TrainingButtonRows<Item:Hashable,Content:View>:View {
    let items:[Item]
    @ViewBuilder let content:(Item)->Content
    var body:some View {
        Grid(alignment:.leading){
            ForEach(Array(stride(from:0,to:items.count,by:3)),id:\.self){start in GridRow{ForEach(items[start..<min(start+3,items.count)],id:\.self){content($0)}}}
        }
    }
}
/// The training library, shown in the board area. Existing mini-games keep their one saved board; new exercises are
/// labelled as such. This is foundational practice, not complete beginner coverage.
struct TrainingLibraryView:View {
    @ObservedObject var model:NativeModel
    @ObservedObject var training:TrainingController
    @ObservedObject var session:GameSession
    /// The entries delivered in this build: Increment A, foundations (plan: Catalog and Delivery).
    /// Without loadable content (`contentError`) the existing games remain, built from their own definitions.
    private var entries:[TrainingEntryDefinition] {guard let catalog=training.catalog else{return Self.legacyEntries};return catalog.entries.filter{$0.increment == .foundations && training.provider?.available($0) != false}}
    static let legacyEntries=MiniGameKind.allCases.map{TrainingEntryDefinition(id:$0.rawValue,title:$0.title,summary:$0.rules,rules:[],objective:.legacyGame,legacyKind:$0,increment:.foundations,delivery:.release,origin:.existing,skills:[],variants:[],lessonLinks:[$0.lessonID],tiers:1)}
    /// Increment B, only where it is enabled: development and automation until an editor has reviewed its content.
    /// Position games also need their own flag.
    private var beginner:[TrainingEntryDefinition] {(training.catalog?.entries ?? []).filter{TrainingRolloutPolicy.preview($0) && training.provider?.available($0) != false}}
    /// Subskills with a scenario still in play: one withdrawn this session (`scenario(_:)` returns nil) cannot start.
    private func variants(_ entry:TrainingEntryDefinition)->[String] {guard let provider=training.provider else{return []};let live=Set(provider.liveScenarios(for:entry.id).map(\.variant));return entry.variants.filter{live.contains($0)}}
    /// The first board suggested for an entry is `training-suggestion-<entry>`; later ones add their order (`-2`, `-3`), so each is targetable.
    static func suggestionIdentifier(_ entry:String,earlier count:Int)->String {"training-suggestion-"+entry+(count==0 ? "":"-\(count+1)")}
    /// Whether this build offers an entry: saved work and suggestions for a disabled increment stay hidden.
    private func offered(_ id:String)->Bool {training.catalog?.entry(id).map(TrainingRolloutPolicy.offered) ?? false}
    var body:some View {ScrollView{VStack(alignment:.leading,spacing:Metrics.padding){
        Text("Training").sectionHeading(.largeTitle.bold())
        Text("Short exercises for the basics. This is foundational practice, not a complete beginner course.").foregroundStyle(.secondary)
        if let error=training.contentError{Text(error).foregroundStyle(Color(nsColor:NativeColors.error))}
        if let notice=training.notice{Text(notice).accessibilityIdentifier("training-notice")}
        ForEach(training.keptForNewerVersion,id:\.self){Text($0).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("training-newer-version")}
        if let active=training.resumable,offered(active.entry),let definition=training.catalog?.entry(active.entry) {
            Button{model.resumeTraining()}label:{Label("Continue \(definition.title)",symbol:.play)}.controlSize(.large).accessibilityIdentifier("training-continue")
        }
        let suggestions=training.suggestions.filter{offered($0.item.entry)}
        if !suggestions.isEmpty {
            Text("Suggested practice").sectionHeading(.title3.bold()).padding(.top,Metrics.smallGap)
            Text("Boards worth another try. Suggestions never lock anything; every entry stays open.").font(.caption).foregroundStyle(.secondary)
            ForEach(Array(suggestions.enumerated()),id:\.element.item.id){position,suggestion in
                HStack(alignment:.top){
                    VStack(alignment:.leading,spacing:2){
                        Text(training.catalog?.entry(suggestion.item.entry)?.title ?? suggestion.item.entry).font(.headline)
                        Text(suggestion.explanation).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    }
                    Spacer(minLength:0)
                    Button(suggestion.due ? String(localized:"Practice Again",bundle:.checkmate):String(localized:"Try It Now",bundle:.checkmate)){model.retryTraining(suggestion.item.id)}.accessibilityIdentifier(Self.suggestionIdentifier(suggestion.item.entry,earlier:suggestions[..<position].filter{$0.item.entry==suggestion.item.entry}.count))
                }
            }
        }
        ForEach([(TrainingOrigin.new,String(localized:"New exercises",bundle:.checkmate)),(.existing,String(localized:"Existing games",bundle:.checkmate))],id:\.0){origin,heading in
            let group=entries.filter{$0.origin==origin}
            if !group.isEmpty{Text("\(heading) (\(group.count))").sectionHeading(.title3.bold()).padding(.top,Metrics.smallGap)}
            ForEach(group,id:\.id){entry in row(entry)}
        }
        if !beginner.isEmpty {
            Text("Beginner skills (\(beginner.count))").sectionHeading(.title3.bold()).padding(.top,Metrics.smallGap)
            Text("Preview: these exercises are machine-checked, but an editor has not reviewed them yet.").font(.caption).foregroundStyle(.secondary)
            ForEach(beginner,id:\.id){entry in row(entry)}
        }
    }.frame(maxWidth:.infinity,alignment:.leading).padding(Metrics.sectionGap)}}
    private func row(_ entry:TrainingEntryDefinition)->some View {Group{
        Button{open(entry)}label:{HStack(alignment:.top){
            (entry.legacyKind != nil ? AppSymbol.gameActivity:.exercise).image.frame(width:Metrics.padding*2).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:2){
                HStack{Text(entry.title).font(.headline);Text(entry.origin == .existing ? String(localized:"Existing game",bundle:.checkmate):entry.increment == .beginner ? String(localized:"Preview",bundle:.checkmate,comment:"Badge: this item can be tried before it is unlocked"):String(localized:"New",bundle:.checkmate,comment:"Badge: this item has not been played yet")).font(.caption).padding(.horizontal,Metrics.tightGap).background(.quaternary,in:Capsule())}
                Text(entry.summary).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Text(TrainingLabels.ruleMode(entry.ruleMode)).font(.caption).foregroundStyle(.secondary)
                ForEach(TrainingRecommendation.progress(entry.id,in:training.training).lines,id:\.self){Text($0).font(.caption)}
                if let kind=entry.legacyKind,session.state.miniGames?[kind.rawValue] != nil{Text("Your saved game resumes.").font(.caption).foregroundStyle(.secondary)}
            }
            Spacer(minLength:0)
        }.contentShape(Rectangle())}.buttonStyle(.plain).accessibilityIdentifier("training-entry-"+entry.id)
        // Only beginner entries offer subskills, so only they look them up.
        if entry.increment == .beginner {
            let subskills=variants(entry)
            if subskills.count>1 {
                TrainingButtonRows(items:subskills){variant in Button(TrainingLabels.variant(variant)){model.startTraining(entry.id,variant:variant)}.controlSize(.small).accessibilityIdentifier("training-variant-\(entry.id)-\(variant)")}
                    .padding(.leading,Metrics.padding*2)
            }
        }
        TrainingLessonLinks(model:model,entry:entry).padding(.leading,Metrics.padding*2)
        if let kind=entry.legacyKind,TrainingRolloutPolicy.beginnerEnabled,let bridge=training.provider?.bridge(for:kind) {
            Button("Try the Same Idea in Normal Chess"){model.startTrainingScenario(bridge.id)}.controlSize(.small).padding(.leading,Metrics.padding*2).accessibilityIdentifier("training-bridge-"+kind.rawValue)
        }
        Divider()
    }}
    private func open(_ entry:TrainingEntryDefinition){
        if let kind=entry.legacyKind{model.playTrainingGame(kind)}else{model.startTraining(entry.id)}
    }
}
/// Hosts the library in the board area; empty while training is not enabled. It always fills its frame: an empty
/// SwiftUI body has a zero ideal size, which NSHostingView turns into maximum-size constraints that fight the
/// board area's edge constraints and break the window's square layout.
struct TrainingLibraryHost:View {
    @ObservedObject var model:NativeModel
    var body:some View {
        Group{if let training=model.training{TrainingLibraryView(model:model,training:training,session:model.session)}else{Color.clear}}
            .frame(maxWidth:.infinity,maxHeight:.infinity)
    }
}
/// An entry's related lessons. Reading one keeps the course bookmark where it was, and the way back leads here.
struct TrainingLessonLinks:View {
    @ObservedObject var model:NativeModel
    /// Observed directly: localized titles change when a language pack finishes, which the model does not forward.
    @ObservedObject private var learning:LearningPlayer
    let entry:TrainingEntryDefinition
    init(model:NativeModel,entry:TrainingEntryDefinition){_model=ObservedObject(wrappedValue:model);_learning=ObservedObject(wrappedValue:model.learning);self.entry=entry}
    var body:some View {
        let lessons=entry.lessonLinks.compactMap{id in learning.library.lessons.firstIndex{$0.id==id}}
        if !lessons.isEmpty {
            VStack(alignment:.leading,spacing:2){
                Text("Related lessons").font(.caption).foregroundStyle(.secondary)
                TrainingButtonRows(items:lessons){index in
                    let lesson=learning.library.lessons[index]
                    Button(learning.localizedTitle(index:index)){model.openTrainingLesson(lesson.id)}.buttonStyle(.link).controlSize(.small).accessibilityIdentifier("training-lesson-\(entry.id)-\(lesson.id)")
                }
            }
        }
    }
}
