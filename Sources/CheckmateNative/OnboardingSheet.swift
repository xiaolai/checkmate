import AppKit
import SwiftUI
import CheckmateCore

/// The first-run welcome's state (L-20): which step is shown and where the learner chose to start. Voice is set up only
/// through the model's consent question, never connected from here directly.
@MainActor final class OnboardingFlow:ObservableObject {
    @Published private(set) var step:Onboarding.Step = .languageAndVoice
    @Published var placement:Onboarding.Placement = .new
    let model:NativeModel
    private let close:()->Void
    init(model:NativeModel,close:@escaping ()->Void){self.model=model;self.close=close}
    func next(){if let next=step.next{step=next}}
    func back(){if let previous=step.previous{step=previous}}
    func skip(){close()}
    /// Closes the welcome and opens the placed lesson, where the first move is made.
    func start(){
        close()
        guard let index=Onboarding.lessonIndex(placement,in:model.learning.library) else{model.storageError=String(localized:"This lesson could not be opened. Nothing was changed.",bundle:.checkmate);return}
        model.lesson(index)
    }
    /// The Settings pane's way in: the consent question first, then the connection.
    func setUpVoice(){model.connectVoiceFromSettings()}
    var lessonTitle:String {Onboarding.lessonIndex(placement,in:model.learning.library).map{model.learning.library.lessons[$0].title} ?? ""}
    var voiceLanguage:Binding<String> {Binding(get:{[model] in model.session.state.settings.voiceLanguage},set:{[model] in var settings=model.session.state.settings;settings.voiceLanguage=$0;model.session.updateSettings(settings)})}
}
struct OnboardingSheet:View {
    @ObservedObject var flow:OnboardingFlow
    @ObservedObject var voice:VoiceCoach
    var body:some View {
        VStack(alignment:.leading,spacing:Metrics.sectionGap) {
            switch flow.step {
            case .languageAndVoice:
                Text("Welcome to Checkmate").sectionHeading(.title2.bold())
                Text("Three quick choices, then your first move.").foregroundStyle(.secondary)
                Picker("Voice coach language",selection:flow.voiceLanguage){ForEach(AppSettings.languages.keys.sorted(),id:\.self){Text(AppSettings.languages[$0]!).tag($0)}}.accessibilityIdentifier("onboarding-voice-language")
                Text("Lessons are in English. You can add another lesson language later in Settings.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Text("The voice coach is optional. It can talk with you about your moves while you practice.").fixedSize(horizontal:false,vertical:true)
                if voice.connected || voice.connecting {Text(voice.status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("onboarding-voice-status")}
                else {Button("Set Up the Voice Coach…"){flow.setUpVoice()}.accessibilityIdentifier("onboarding-voice-setup")}
            case .placement:
                Text("Where would you like to start?").sectionHeading(.title2.bold())
                Picker("Where to start",selection:$flow.placement){ForEach(Onboarding.Placement.allCases,id:\.self){Text($0.title).tag($0)}}.pickerStyle(.radioGroup).labelsHidden().accessibilityIdentifier("onboarding-placement")
                Text("You can open any lesson from the sidebar at any time.").font(.caption).foregroundStyle(.secondary)
            case .firstMove:
                Text("Your first move").sectionHeading(.title2.bold())
                Text("To move a piece, click it, then click the square it should go to. You can also drag it there.").fixedSize(horizontal:false,vertical:true)
                Text("Your first lesson: \(flow.lessonTitle)").accessibilityIdentifier("onboarding-first-lesson")
            }
            HStack {
                Button("Skip"){flow.skip()}.accessibilityIdentifier("onboarding-skip")
                Spacer()
                if flow.step.previous != nil {Button("Back"){flow.back()}.accessibilityIdentifier("onboarding-back")}
                if flow.step.next != nil {Button("Continue"){flow.next()}.keyboardShortcut(.defaultAction).accessibilityIdentifier("onboarding-continue")}
                else {Button("Start Lesson"){flow.start()}.keyboardShortcut(.defaultAction).accessibilityIdentifier("onboarding-start")}
            }
        }.padding(Metrics.sectionGap*1.5).frame(width:460,alignment:.leading)
    }
}
extension GameWindow {
    /// Shows the first-run welcome as a sheet on the game window; it closes itself when started or skipped.
    func showOnboarding(){
        guard let window else{return}
        var sheet:NSWindow?
        let flow=OnboardingFlow(model:model){[weak window] in if let sheet{window?.endSheet(sheet)};sheet=nil}
        let host=NSHostingController(rootView:OnboardingSheet(flow:flow,voice:model.voice))
        let made=NSWindow(contentViewController:host);made.identifier=NSUserInterfaceItemIdentifier("onboarding");made.title=String(localized:"Welcome to Checkmate",bundle:.checkmate)
        sheet=made;window.beginSheet(made)
    }
}
