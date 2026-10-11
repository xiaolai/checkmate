import AppKit
import SwiftUI
import CheckmateCore

struct LessonSettingsPane:View {
    @ObservedObject var controller:LessonLanguageController
    @ObservedObject var session:GameSession
    @ObservedObject var coach:VoiceCoach
    let library:CourseLibrary
    @State private var search=""
    @State private var customLocale=""
    private var languages:[String] {
        LessonLanguages.supported.filter{search.isEmpty || name($0).localizedCaseInsensitiveContains(search) || $0.localizedCaseInsensitiveContains(search)}.sorted{name($0)<name($1)}
    }
    private func name(_ code:String)->String {Locale(identifier:"en").localizedString(forIdentifier:code) ?? code}
    private var audioConflict:Bool {coach.connected || coach.connecting}
    private func select(language:String?=nil,voice:String?=nil) {
        var settings=session.state.settings
        if let language,let normalized=LessonLanguages.normalizedSelection(language){settings.lessonLanguage=normalized;controller.language=normalized}
        if let voice{settings.lessonVoice=voice;controller.voice=voice}
        session.updateSettings(settings)
    }
    var body:some View {
        Section("Lesson language") {
            TextField("Search languages",text:$search).accessibilityIdentifier("lesson-language-search")
            Picker("Language",selection:Binding(get:{controller.language},set:{select(language:$0)})) {
                ForEach(Array(Set(languages+[controller.language])).sorted{name($0)<name($1)},id:\.self){Text(name($0)).tag($0)}
            }.disabled(controller.busy).accessibilityIdentifier("lesson-language")
            HStack{TextField("Custom language / locale",text:$customLocale).accessibilityIdentifier("lesson-custom-locale");Button("Use language"){let locale=customLocale.trimmingCharacters(in:.whitespacesAndNewlines);select(language:locale)}.disabled(controller.busy || LessonLanguages.normalizedSelection(customLocale)==nil)}
            Text("Choose a language, then translate explicitly. Language selection does not start a request. Speech quality varies by language.").font(.caption).foregroundStyle(.secondary)
            Picker("Scope",selection:$controller.allLessons){Text("Selected lesson").tag(false);Text("All lessons").tag(true)}.disabled(controller.busy)
            Picker("Lesson",selection:$controller.selectedLesson){ForEach(Array(library.lessons.enumerated()),id:\.element.id){index,lesson in Text(lesson.title).tag(index)}}.disabled(controller.busy || controller.allLessons)
            Picker("Recording voice",selection:Binding(get:{controller.voice},set:{select(voice:$0)})){Text("Cedar").tag("cedar");Text("Marin").tag("marin")}.disabled(controller.busy)
            HStack {
                Button("Translate"){controller.translate()}.disabled(controller.busy || controller.language=="en").accessibilityIdentifier("lesson-translate")
                Button("Generate preview"){controller.preview()}.disabled(controller.busy || audioConflict || controller.language=="en")
                Button("Play preview"){if let url=controller.previewURL{controller.playPreview?(url)}}.disabled(controller.busy || audioConflict || controller.previewURL==nil)
            }
            HStack {
                Button("Record / Resume"){controller.record()}.disabled(controller.busy || audioConflict || controller.language=="en")
                Button("Cancel"){controller.cancel()}.disabled(!controller.busy).accessibilityIdentifier("lesson-job-cancel")
                Button("Remove stored lesson",role:.destructive){confirmRemove()}.disabled(controller.busy || controller.language=="en")
            }
            Button("Discard translated text…",role:.destructive){confirmDiscard()}.disabled(controller.busy || (!controller.allLessons && controller.inspection.isEmpty))
            if audioConflict{Text("Disconnect the voice coach before generating or playing lesson recordings.").font(.caption).foregroundStyle(.secondary)}
            if controller.busy{ProgressView().controlSize(.small)}
            Text(controller.storedStatus).font(.caption).foregroundStyle(.secondary)
            Text(controller.status).textSelection(.enabled).accessibilityIdentifier("lesson-job-status")
            Text("Transcript verification compares the provider’s transcript with the requested script. Listen to the preview to judge spoken accuracy, clarity and suitability before recording the full lesson.").font(.caption).foregroundStyle(.secondary)
            Text("A lesson uses the selected language after all its recordings are complete. Otherwise, the whole lesson plays in English.").font(.caption).foregroundStyle(.secondary)
        }
        if !controller.inspection.isEmpty {
            Section("Translated text") {ScrollView{Text(controller.inspection).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(minHeight:Metrics.lessonInspectionMinimum,maxHeight:Metrics.lessonInspectionMaximum)}
        }
    }
    private func confirmDiscard(){
        let alert=NSAlert();alert.messageText="Discard translated text?";alert.informativeText="This removes cached translated text and its recordings for the chosen scope, so Translate can request fresh text. Your progress and bundled English lessons are kept.";let discard=alert.addButton(withTitle:"Discard");discard.keyEquivalent="";let cancel=alert.addButton(withTitle:"Cancel");cancel.keyEquivalent="\r";alert.window.defaultButtonCell=cancel.cell as? NSButtonCell
        if alert.runModal() == .alertFirstButtonReturn{controller.discardTranslation()}
    }
    private func confirmRemove(){
        let alert=NSAlert();alert.messageText="Remove stored lesson language?";alert.informativeText="This removes recordings for the selected language, voice and scope. Translated text, progress and bundled English lessons are kept.";let remove=alert.addButton(withTitle:"Remove");remove.keyEquivalent="";let cancel=alert.addButton(withTitle:"Cancel");cancel.keyEquivalent="\r";alert.window.defaultButtonCell=cancel.cell as? NSButtonCell
        if alert.runModal() == .alertFirstButtonReturn{controller.remove()}
    }
}
