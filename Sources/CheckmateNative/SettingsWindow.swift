import AppKit
import Combine
import SwiftUI
import CheckmateCore
/// A settings pane; the raw value is the saved identifier and `title` is only what the sidebar shows (D-12).
enum SettingsCategory:String,CaseIterable,Identifiable {case board,sound,lessons,practice,voice,connections,usage,about;var id:String{rawValue}
    var title:String{switch self{case .board:return String(localized:"Chessboard",bundle:.checkmate);case .sound:return String(localized:"Sound",bundle:.checkmate);case .lessons:return String(localized:"Lessons",bundle:.checkmate);case .practice:return String(localized:"Practice",bundle:.checkmate);case .voice:return String(localized:"Voice Coach",bundle:.checkmate);case .connections:return String(localized:"Connections",bundle:.checkmate);case .usage:return String(localized:"Usage",bundle:.checkmate);case .about:return String(localized:"About",bundle:.checkmate)}}
    /// Saves before stable identifiers stored the shown title; those titles stay fixed here even if a title changes.
    init(stored:String){self=Self(rawValue:stored) ?? Self.legacy[stored] ?? .board}
    static let legacy:[String:SettingsCategory]=["Chessboard":.board,"Sound":.sound,"Lessons":.lessons,"Practice":.practice,"Voice Coach":.voice,"Connections":.connections,"Usage":.usage,"About":.about]
var symbol:AppSymbol{switch self{case .board:return .board;case .sound:return .sound;case .lessons:return .lesson;case .practice:return .practice;case .voice:return .voice;case .connections:return .connections;case .usage:return .usage;case .about:return .about}}}
private final class SettingsSelection:ObservableObject {@Published var category:SettingsCategory? = .board}
private struct SettingsSidebar:View {@ObservedObject var selection:SettingsSelection;var body:some View{List(SettingsCategory.allCases,selection:$selection.category){c in Label(c.title,symbol:c.symbol).tag(c)}.listStyle(.sidebar).scrollContentBackground(.hidden)}}
private struct SettingsForm:View {
    @ObservedObject var selection:SettingsSelection
    @ObservedObject var session:GameSession
    @ObservedObject var voice:VoiceCoach
    @ObservedObject var companion:CompanionBroker
    @State private var companionSetupStatus = ""
    /// The first line Codex wrote when Set up or Remove failed, shown under Details.
    @State private var companionSetupDetails:String?
    @State private var companionSetupRunning = false
    /// The consent sheet, the voice connection and the Codex registration check live on the model.
    let model:NativeModel
    @State private var codexSetup:CompanionInstallation.SetupCheck?
    @ObservedObject var voiceAudio:VoiceAudio
    @ObservedObject var preview:VoicePreview
    let about:AboutFacts
    let lessonLanguages:LessonLanguageController
    let usage:UsageLedger
    let library:CourseLibrary
    func binding<T>(_ key:WritableKeyPath<AppSettings,T>)->Binding<T> {Binding(get:{session.state.settings[keyPath:key]},set:{var s=session.state.settings;s[keyPath:key]=$0;session.updateSettings(s)})}
    private func removeCodexSetup() {
        guard !NativePolicy.silent else {companionSetupStatus=String(localized:"Codex setup is disabled during automation.",bundle:.checkmate);return}
        guard let codex=CompanionInstallation.installedCodex() else {companionSetupStatus=String(localized:"Codex is not installed, so there is no Checkmate setup in it to remove.",bundle:.checkmate);return}
        let alert=NSAlert.destructive(String(localized:"Remove Checkmate from Codex?",bundle:.checkmate),String(localized:"Codex will no longer start Checkmate’s chess tools, and Checkmate’s companion skill is removed. A skill you edited is kept.",bundle:.checkmate),action:String(localized:"Remove",bundle:.checkmate))
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        companionSetupRunning=true;companionSetupDetails=nil
        Task {
            do {
                let skill=try Data(contentsOf:NativeResources.url("companion-skill.md"))
                let removal=try await Task.detached {try CompanionInstallation.unregister(codex:codex,bundledSkill:skill)}.value
                switch removal {case .removed:companionSetupStatus=String(localized:"Removed from Codex, with Checkmate’s companion skill.",bundle:.checkmate);case .absent:companionSetupStatus=String(localized:"Removed from Codex. No companion skill was installed.",bundle:.checkmate);case .kept:companionSetupStatus=String(localized:"Removed from Codex. Your edited companion skill was kept.",bundle:.checkmate)}
            } catch {companionSetupStatus=userFacingMessage(error,fallback:String(localized:"Codex setup could not be removed.",bundle:.checkmate));companionSetupDetails=(error as? CompanionInstallation.CodexCommandFailure)?.details}
            companionSetupRunning=false;model.refreshCodexSetup()
        }
    }
    /// Whether the installed companion skill matches this version; read only, never written at launch.
    private var skillNote:String? {
        guard let bundled=try? Data(contentsOf:NativeResources.url("companion-skill.md")) else{return nil}
        switch CompanionInstallation.skillState(bundled:bundled) {
        case .outdated:return String(localized:"The installed companion skill is from an older Checkmate. Choose Set Up Codex to update it.",bundle:.checkmate)
        case .customized:return String(localized:"Your companion skill differs from this version’s and is kept as it is. To use this version’s, remove ~/.codex/skills/\(CompanionInstallation.skillName()), then choose Set Up Codex.",bundle:.checkmate)
        case .notInstalled,.current:return nil
        }
    }
    private func setUpCodex() {
        guard !NativePolicy.silent else {companionSetupStatus=String(localized:"Codex setup is disabled during automation.",bundle:.checkmate);return}
        if let problem=CompanionInstallation.launchLocationProblem(bundle:Bundle.main.bundleURL) {companionSetupStatus=problem;return}
        guard let codex=CompanionInstallation.installedCodex(),let directory=Bundle.main.executableURL?.deletingLastPathComponent() else {companionSetupStatus=String(localized:"Install Codex on this Mac first.",bundle:.checkmate);return}
        let executable=directory.appendingPathComponent("CheckmateMCP")
        companionSetupRunning=true;companionSetupDetails=nil
        Task {
            do {
                let skill=try Data(contentsOf:NativeResources.url("companion-skill.md"))
                let state=try await Task.detached {try CompanionInstallation.register(executable:executable,codex:codex,skill:skill)}.value
                companionSetupStatus=Sentences.join(SettingsWindow.setupReady(connectionsAllowed:companion.enabled,skill:CompanionInstallation.skillName()),state == .customized ? String(localized:"Your customized companion skill was kept.",bundle:.checkmate):"")
            } catch {companionSetupStatus=userFacingMessage(error,fallback:String(localized:"Codex setup failed. Check that Codex is installed and try again.",bundle:.checkmate));companionSetupDetails=(error as? CompanionInstallation.CodexCommandFailure)?.details}
            companionSetupRunning=false;model.refreshCodexSetup()
        }
    }
    /// A registration Codex keeps for another copy of Checkmate (moved, renamed or deleted) is offered a repair,
    /// which registers this copy in its place.
    @ViewBuilder private var codexSetupNote:some View {
        switch codexSetup {
        case .stale(let registered)?:
            Text("Codex starts Checkmate from \(registered), which is not this copy, so the companion may not work.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Button("Repair Codex Setup"){setUpCodex()}.disabled(companionSetupRunning).accessibilityIdentifier("repair-codex-setup")
        case .unknown?:
            Text("Checkmate could not read its entry in Codex’s configuration. If Codex cannot start Checkmate, choose Set Up Codex.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        case .notSetUp?,.current?,nil:EmptyView()
        }
    }
    var body:some View {Form {
        switch selection.category ?? .board {
        case .usage:
            UsageSettingsPane(ledger:usage,controller:lessonLanguages)
        case .about:
            AboutPane(facts:about)
            Section{Toggle("Check for Updates Automatically",isOn:binding(\.checkForUpdates))} header:{Text("Updates")} footer:{Text("When this is on, Checkmate asks GitHub for the latest release each time it opens. Checkmate ▸ Check for Updates… asks at any time.").foregroundStyle(.secondary)}
        case .connections:
            Section("Codex companion"){Button(companionSetupRunning ? String(localized:"Working…",bundle:.checkmate) : String(localized:"Set Up Codex",bundle:.checkmate)){setUpCodex()}.disabled(companionSetupRunning);Button("Remove Codex Setup…"){removeCodexSetup()}.disabled(companionSetupRunning);if !companionSetupStatus.isEmpty{Text(companionSetupStatus).foregroundStyle(.secondary);if let details=companionSetupDetails{DisclosureGroup("Details"){Text(details).font(.caption).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)}}}else if let note=skillNote{Text(note).foregroundStyle(.secondary)};codexSetupNote;Text(companion.status);Toggle("Accept Codex connections at launch",isOn:binding(\.companionAutoStart));Toggle("Allow Codex connections",isOn:Binding(get:{companion.enabled},set:{on in if on{do{try companion.enable(role:session.state.settings.companionRole,standby:true)}catch{companion.disable()}}else{companion.disable()}}));Picker("Companion role",selection:binding(\.companionRole)){Text("Coach").tag("coach");Text("Opponent (Black)").tag("opponent")}.disabled(companion.enabled);if companion.connected{Button("Disconnect Companion"){companion.disconnectCurrentClient()}};if let error=companion.error{Text(error).foregroundStyle(.secondary)}}
            Section {Text("The Codex companion is a Codex task on this Mac that can see your board, coach you, or play against you, using Checkmate’s chess tools. Set Up Codex adds Checkmate to Codex once; after that, Checkmate waits on this Mac for a Codex task to connect. While the voice coach is connected, Codex is asked to wait; disconnect voice to use the companion.").foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
        case .voice:
            VoiceSettingsContent(session:session,voice:voice,voiceAudio:voiceAudio,preview:preview,model:model)
        case .board:
            Section("Appearance"){Picker("Board theme",selection:binding(\.boardTheme)){ForEach(["wood","green","blue","neutral"],id:\.self){Text(AppSettings.themes[$0]!).tag($0)}}}
            Section("Animation"){Picker("Piece movement",selection:binding(\.pieceDuration)){Text("Off").tag(0);Text("Fast").tag(300);Text("Medium").tag(500);Text("Slow").tag(700)}}
        case .sound:
            Section("Move sounds"){Toggle("Piece and move sounds",isOn:binding(\.moveSounds));Slider(value:binding(\.effectsVolume),in:0...1){Text("Effects volume")}.disabled(!session.state.settings.moveSounds)}
        case .lessons:
            LessonSettingsPane(controller:lessonLanguages,session:session,coach:voice,library:library)
            Section {Toggle("Narration",isOn:binding(\.narration));Slider(value:binding(\.volume),in:0...1){Text("Narration volume")}.disabled(!session.state.settings.narration);Toggle("Continue automatically",isOn:binding(\.autoAdvance));Toggle("Pause for practice",isOn:binding(\.pauseForPractice))} header:{Text("Lesson playback")} footer:{Text("Bundled English narration uses OpenAI Cedar. Generated lesson recordings use your selected voice and are AI-generated. Continue automatically plays the next transcript and starts the next lesson when this one ends, skipping practice activities. Pause for practice stops at the end of a lesson that has a game or practice activity so you can try it before continuing.")}
        case .practice:
            Section("Opponent"){OpponentSettingsContent(session:session)}
            Section("Guidance"){Picker("Practice guidance",selection:binding(\.coachingMode)){Text("Guided game").tag("guided");Text("On request").tag("on_request");Text("Quiet").tag("quiet")}}
            Section{Toggle("Analyze When Opened",isOn:binding(\.reviewAutoAnalyze)).accessibilityIdentifier("review-auto-analyze")} header:{Text("Game review")} footer:{Text("Opening a game for review analyzes it with Stockfish. Moves already analyzed are not searched again, and nothing is analyzed during a network game.").foregroundStyle(.secondary)}
        }
    }.formStyle(.grouped).frame(minWidth:Metrics.settingsDetailMinimum,minHeight:Metrics.settingsFormMinimumHeight).onReceive(model.$codexSetup){codexSetup=$0}.onChange(of:selection.category){_,category in session.state.window.settingsCategory=(category ?? .board).rawValue;session.emit(semantic:false,save:true)}}
}
@MainActor final class SettingsWindow:NSWindowController,NSToolbarDelegate {
    /// Escape closes Settings, as ⌘W (File ▸ Close) does.
    override func cancelOperation(_ sender:Any?){window?.performClose(sender)}
    private let selection=SettingsSelection(),titleID=NSToolbarItem.Identifier("settings.title"),titleLabel=textLabel(String(localized:"Settings",bundle:.checkmate),.title3,.semibold)
    private var titleFollowsPane:AnyCancellable?
    init(model:NativeModel){selection.category=SettingsCategory(stored:model.session.state.window.settingsCategory);let w=NSWindow(contentRect:NSRect(x:0,y:0,width:Metrics.settingsWidth,height:Metrics.settingsHeight),styleMask:[.titled,.closable,.fullSizeContentView],backing:.buffered,defer:false);super.init(window:w)
        // Titled by its pane (V-23); the identifier stays "Settings" so automation and the Window menu can find it.
        w.title=String(localized:"Settings",bundle:.checkmate);w.identifier=NSUserInterfaceItemIdentifier("Settings");w.titleVisibility = .hidden;w.isReleasedWhenClosed=false;w.autorecalculatesKeyViewLoop=true
        let split=NSSplitViewController(),side=NSSplitViewItem(sidebarWithViewController:NSHostingController(rootView:SettingsSidebar(selection:selection))),detail=NSSplitViewItem(viewController:NSHostingController(rootView:SettingsForm(selection:selection,session:model.session,voice:model.voice,companion:model.companion,model:model,voiceAudio:model.voice.audio,preview:model.voicePreview,about:AboutFacts(model:model),lessonLanguages:model.lessonLanguages,usage:model.usage,library:model.learning.library)))
        side.canCollapse=false;side.minimumThickness=Metrics.settingsSidebar;side.maximumThickness=Metrics.settingsSidebar;side.allowsFullHeightLayout=true;side.titlebarSeparatorStyle = .none;detail.titlebarSeparatorStyle = .automatic;split.addSplitViewItem(side);split.addSplitViewItem(detail);w.contentViewController=split
        let toolbar=NSToolbar(identifier:"Settings.Toolbar");toolbar.delegate=self;toolbar.displayMode = .iconOnly;toolbar.centeredItemIdentifiers=[titleID];w.toolbar=toolbar;w.toolbarStyle = .unified;w.setContentSize(NSSize(width:Metrics.settingsWidth,height:Metrics.settingsHeight));w.center()
        // The titlebar is opaque with a separator over the scrolling form, so a scrolled section no longer slides under the title.
        titleFollowsPane=selection.$category.sink{[weak self] category in let title=category?.title ?? String(localized:"Settings",bundle:.checkmate);self?.window?.title=title;self?.titleLabel.stringValue=title}
    }
    func selectCategory(_ value:SettingsCategory){selection.category=value}
    /// Opens Settings on one pane, as a failure's button does (V-27).
    func show(category:SettingsCategory){selection.category=category;showWindow(nil);window?.makeKeyAndOrderFront(nil)}
    var shownCategory:SettingsCategory? {selection.category}
    /// What to do after Set Up Codex, from whether connections are already allowed (V-14).
    nonisolated static func setupReady(connectionsAllowed:Bool,skill:String)->String {connectionsAllowed ? String(localized:"Ready. Start a new Codex task using $\(skill).",bundle:.checkmate):String(localized:"Ready. Turn on Allow Codex connections below, then start a new Codex task using $\(skill).",bundle:.checkmate)}
    required init?(coder:NSCoder){fatalError()}
    func toolbarDefaultItemIdentifiers(_ t:NSToolbar)->[NSToolbarItem.Identifier]{[.flexibleSpace,titleID,.flexibleSpace]}
    func toolbarAllowedItemIdentifiers(_ t:NSToolbar)->[NSToolbarItem.Identifier]{toolbarDefaultItemIdentifiers(t)}
    func toolbar(_ t:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar:Bool)->NSToolbarItem?{let item=NSToolbarItem(itemIdentifier:id);item.view=titleLabel;item.isBordered=false;item.label=String(localized:"Settings",bundle:.checkmate);return item}
}
