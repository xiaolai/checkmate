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
    @State private var clip=0
    private var languages:[String] {
        LessonLanguages.supported.filter{search.isEmpty || name($0).localizedCaseInsensitiveContains(search) || $0.localizedCaseInsensitiveContains(search)}.sorted{name($0)<name($1)}
    }
    private func name(_ code:String)->String {Locale(identifier:"en").localizedString(forIdentifier:code) ?? code}
    private var audioConflict:Bool {coach.connected || coach.connecting}
    /// Play preview obeys the Narration switch and volume, like lesson narration; a muted preview says so instead of
    /// playing silently.
    private var narrationAudible:Bool {AudioPolicy.narrationAudible(session.state.settings)}
    private var clipTitles:[String] {library.stepTitles.indices.contains(controller.selectedLesson) ? library.stepTitles[controller.selectedLesson]:[]}
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
                Button("Play preview"){if let url=controller.previewURL{controller.playPreview?(url)}}.disabled(controller.busy || audioConflict || controller.previewURL==nil || !narrationAudible)
            }
            if controller.previewURL != nil,!narrationAudible{Text("Turn on Narration and raise Narration volume under Lesson playback to hear the preview.").font(.caption).foregroundStyle(.secondary)}
            HStack {
                Button("Record / Resume"){controller.record()}.disabled(controller.busy || audioConflict || controller.language=="en")
                Button("Cancel"){controller.cancel()}.disabled(!controller.canCancel).accessibilityIdentifier("lesson-job-cancel")
                Button("Remove stored lesson",role:.destructive){confirmRemove()}.disabled(controller.busy || controller.language=="en")
            }
            // One bad clip is re-recorded alone: remove it, then Record / Resume records only what is missing.
            HStack {
                Picker("Clip",selection:$clip){ForEach(Array(clipTitles.enumerated()),id:\.offset){index,title in Text("\(index+1). \(title)").tag(index)}}.accessibilityIdentifier("lesson-clip")
                Button("Remove clip",role:.destructive){confirmRemoveClip()}.accessibilityIdentifier("lesson-remove-clip")
            }.disabled(controller.busy || controller.allLessons || controller.language=="en").onChange(of:controller.selectedLesson){clip=0}
            Button("Discard translated text…",role:.destructive){confirmDiscard()}.disabled(!controller.canDiscardTranslation)
            Button("Remove outdated translations…"){confirmPurge()}.disabled(controller.busy)
            if audioConflict{Text("Disconnect the voice coach before generating or playing lesson recordings.").font(.caption).foregroundStyle(.secondary)}
            if controller.busy{ProgressView().controlSize(.small)}
            Text(controller.storedStatus).font(.caption).foregroundStyle(.secondary)
            Text(controller.status).textSelection(.enabled).accessibilityIdentifier("lesson-job-status")
            if !controller.problems.isEmpty{VStack(alignment:.leading,spacing:4){ForEach(Array(controller.problems.enumerated()),id:\.offset){_,problem in Text("• "+problem).textSelection(.enabled)}}.font(.caption).accessibilityElement(children:.contain).accessibilityLabel("Lesson job problems").accessibilityIdentifier("lesson-job-problems")}
            Text("Transcript verification compares the provider’s transcript with the requested script. Listen to the preview to judge spoken accuracy, clarity and suitability before recording the full lesson.").font(.caption).foregroundStyle(.secondary)
            Text("A lesson uses the selected language after all its recordings are complete. Otherwise, the whole lesson plays in English.").font(.caption).foregroundStyle(.secondary)
        }
        if !controller.inspection.isEmpty {
            Section("Translated text") {ScrollView{Text(controller.inspection).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(minHeight:Metrics.lessonInspectionMinimum,maxHeight:Metrics.lessonInspectionMaximum)}
        }
    }
    private func confirmPurge(){
        confirm("Remove outdated translations?","This removes translated text and recordings made for earlier versions of these lessons, which this version can no longer use. Current translations, recordings and your progress are kept.",action:"Remove"){controller.purgeOutdated()}
    }
    private func confirmDiscard(){
        confirm("Discard translated text?","This removes cached translated text and its recordings for the chosen scope, so Translate can request fresh text. Your progress and bundled English lessons are kept.",action:"Discard"){controller.discardTranslation()}
    }
    private func confirmRemoveClip(){
        confirm("Remove clip \(clip+1)?","This removes one recording for the selected language, voice and lesson. Record / Resume then records only that clip again; until then the lesson plays in English.",action:"Remove"){controller.removeClip(step:clip)}
    }
    private func confirmRemove(){
        confirm("Remove stored lesson language?","This removes recordings for the selected language, voice and scope. Translated text, progress and bundled English lessons are kept.",action:"Remove"){controller.remove()}
    }
    /// A destructive confirmation: Cancel is the default (Return) button, and the action runs only when chosen.
    private func confirm(_ title:String,_ message:String,action:String,perform:()->Void){
        let alert=NSAlert.destructive(title,message,action:action)
        if alert.runModal() == .alertFirstButtonReturn{perform()}
    }
}
