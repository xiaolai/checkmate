import AppKit
import Combine
import CheckmateCore

/// What surrounds the coach's conversation: a typed question (V-3), the one action each failure offers (V-6, V-27),
/// whether this Mac has what voice needs (V-5) and VoiceOver announcements (V-21). Every press that reaches OpenAI goes
/// through `NativeModel.connectVoiceWithConsent`.
@MainActor final class VoiceHelp:ObservableObject {
    static let microphoneSettings=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let getCodex=URL(string:"https://openai.com/codex/")!
    /// Opens a Settings pane; the window sets it.
    var showSettings:(SettingsCategory)->Void={_ in}
    /// Speaks to VoiceOver; the window sets it.
    var announce:(String)->Void={_ in}
    /// Opens a link or a System Settings pane. Automation records the request in the data directory instead, so tests
    /// stay silent and can still see the press arrive.
    var openURL:(URL)->Void={_ in}
    /// A typed question waiting for the coach to connect; it is dropped if the connection does not open.
    @Published private(set) var pendingQuestion:String?
    private weak var model:NativeModel?
    private var announced=Set<String>()
    private var observations=Set<AnyCancellable>()

    func attach(_ model:NativeModel){
        self.model=model;let voice=model.voice,directory=model.store.directory
        openURL={url in if NativePolicy.silent{Self.record(url,in:directory)}else{NSWorkspace.shared.open(url)}}
        voice.keepModelChoice(at:directory.appendingPathComponent("voice-model.json"))
        // The capability is read from the file system only, at launch and whenever the app comes back, so installing
        // Codex or signing in while Checkmate runs is noticed. Automation keeps it unchecked unless a test sets it.
        if !NativePolicy.silent {
            voice.refreshCapability()
            NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification).sink{[weak voice] _ in voice?.refreshCapability()}.store(in:&observations)
        }
        // Published before it changes: read the state on the next main-loop turn.
        voice.$connection.sink{[weak self] _ in DispatchQueue.main.async{self?.connectionChanged()}}.store(in:&observations)
        voice.$failure.compactMap{$0}.receive(on:RunLoop.main).sink{[weak self] failure in self?.announce(failure.cause)}.store(in:&observations)
        voice.$microphoneFailure.removeDuplicates().compactMap{$0}.receive(on:RunLoop.main).sink{[weak self] failure in self?.announce(failure.cause)}.store(in:&observations)
        announced=Set(voice.history.map(\.id))
        voice.$history.receive(on:RunLoop.main).sink{[weak self] history in self?.historyChanged(history)}.store(in:&observations)
    }
    /// V-3: asks the coach a typed question, connecting it first (without a greeting) when it is not connected.
    func ask(_ text:String){
        let question=text.trimmingCharacters(in:.whitespacesAndNewlines);guard !question.isEmpty,let model else{return}
        model.connectVoiceWithConsent{[weak self,weak model] in
            guard let self,let model else{return};let voice=model.voice
            if voice.connected{voice.ask(question);return}
            if !voice.connecting{if model.session.mode == .training{voice.connectTraining()}else{voice.connect(greet:false)}}
            // Set after connecting: connecting first disconnects, which would drop a question already waiting.
            if voice.connecting{pendingQuestion=question}
        }
    }
    /// What a failure's button does: one place per action.
    func perform(_ action:VoiceAction,retry:()->Void){
        switch action {
        case .openMicrophoneSettings:openURL(Self.microphoneSettings)
        case .getCodex:openURL(Self.getCodex)
        case .signIn,.openVoiceSettings:showSettings(.voice)
        case .setUpCodex:showSettings(.connections)
        case .tryAgain:retry()
        }
    }
    private func connectionChanged(){
        guard let voice=model?.voice,pendingQuestion != nil else{return}
        switch voice.connection {
        case .ready:let question=pendingQuestion!;pendingQuestion=nil;voice.ask(question)
        case .authorizing,.connecting:break
        default:pendingQuestion=nil
        }
    }
    /// Each coach answer is announced once, when it arrives.
    private func historyChanged(_ history:[VoiceHistory]){
        if history.isEmpty{announced=[];return}
        for entry in history where entry.role=="coach" && !announced.contains(entry.id){announced.insert(entry.id);announce(entry.text)}
        for entry in history where entry.role != "coach"{announced.insert(entry.id)}
    }
    private static func record(_ url:URL,in directory:URL){
        let log=directory.appendingPathComponent("opened-urls.txt"),line=Data((url.absoluteString+"\n").utf8)
        do {
            if FileManager.default.fileExists(atPath:log.path){let handle=try FileHandle(forWritingTo:log);try handle.seekToEnd();try handle.write(contentsOf:line);try handle.close()}
            else{try line.write(to:log)}
        } catch {NativeLog.voice.error("Could not record an opened link: \(error.localizedDescription, privacy: .public)")}
    }
}
