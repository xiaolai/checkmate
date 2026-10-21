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
    // L-26: the pane is split by task (choose the language, choose lessons, run a job, manage what is stored), and the
    // lesson picker and list follow the course's sections.
    var body:some View {
        Section("Lesson language") {
            TextField("Search languages",text:$search).accessibilityIdentifier("lesson-language-search")
            Picker("Language",selection:Binding(get:{controller.language},set:{select(language:$0)})) {
                ForEach(Array(Set(languages+[controller.language])).sorted{name($0)<name($1)},id:\.self){Text(name($0)).tag($0)}
            }.disabled(controller.busy).accessibilityIdentifier("lesson-language")
            HStack{TextField("Custom language / locale",text:$customLocale).accessibilityIdentifier("lesson-custom-locale");Button("Use Language"){let locale=customLocale.trimmingCharacters(in:.whitespacesAndNewlines);select(language:locale)}.disabled(controller.busy || LessonLanguages.normalizedSelection(customLocale)==nil)}
            Picker("Recording voice",selection:Binding(get:{controller.voice},set:{select(voice:$0)})){Text("Cedar").tag("cedar");Text("Marin").tag("marin")}.disabled(controller.busy)
            Text("Choose a language, then translate explicitly. Language selection does not start a request. Speech quality varies by language.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Lessons") {
            Picker("Scope",selection:$controller.allLessons){Text("Selected lesson").tag(false);Text("All lessons").tag(true)}.disabled(controller.busy)
            Picker("Lesson",selection:$controller.selectedLesson){ForEach(groups,id:\.lessons){group in Section(group.title){ForEach(group.lessons,id:\.self){Text(library.lessons[$0].title).tag($0)}}}}.disabled(controller.busy || controller.allLessons).accessibilityIdentifier("lesson-picker")
            if controller.language != "en"{lessonList}
        }
        Section("Translate and record") {
            HStack {
                Button("Translate"){if controller.allLessons{confirmAll("translate")}else{controller.translate()}}.disabled(controller.busy || controller.planning || controller.language=="en").accessibilityIdentifier("lesson-translate")
                Button("Generate Preview"){controller.preview()}.disabled(controller.busy || audioConflict || controller.language=="en")
                Button("Play Preview"){if let url=controller.previewURL{controller.playPreview?(url)}}.disabled(controller.busy || audioConflict || controller.previewURL==nil || !narrationAudible)
            }
            if controller.previewURL != nil,!narrationAudible{Text("Turn on Narration and raise Narration volume under Lesson playback to hear the preview.").font(.caption).foregroundStyle(.secondary)}
            HStack {
                Button("Record / Resume"){if controller.allLessons{confirmAll("record")}else{controller.record()}}.disabled(controller.busy || controller.planning || audioConflict || controller.language=="en")
                Button("Cancel"){controller.cancel()}.disabled(!controller.canCancel).accessibilityIdentifier("lesson-job-cancel")
            }
            if audioConflict{Text("Disconnect the voice coach before generating or playing lesson recordings.").font(.caption).foregroundStyle(.secondary)}
            if controller.busy{ProgressView().controlSize(.small)}
            Text(controller.status).textSelection(.enabled).accessibilityIdentifier("lesson-job-status")
            if !controller.problems.isEmpty{VStack(alignment:.leading,spacing:Metrics.tightGap){ForEach(Array(controller.problems.enumerated()),id:\.offset){_,problem in Text("• "+problem).textSelection(.enabled)}}.font(.caption).accessibilityElement(children:.contain).accessibilityLabel("Lesson job problems").accessibilityIdentifier("lesson-job-problems")}
            Text("Transcript verification compares the provider’s transcript with the requested script. Listen to the preview to judge spoken accuracy, clarity and suitability before recording the full lesson.").font(.caption).foregroundStyle(.secondary)
            Text("A lesson uses the selected language after all its recordings are complete. Otherwise, the whole lesson plays in English.").font(.caption).foregroundStyle(.secondary)
        }
        Section("Stored lessons") {
            Text(controller.storedStatus).font(.caption).foregroundStyle(.secondary)
            Button("Remove Stored Lesson",role:.destructive){confirmRemove()}.disabled(controller.busy || controller.language=="en")
            // One bad clip is re-recorded alone: remove it, then Record / Resume records only what is missing.
            HStack {
                Picker("Clip",selection:$clip){ForEach(Array(clipTitles.enumerated()),id:\.offset){index,title in Text("\(index+1). \(title)").tag(index)}}.accessibilityIdentifier("lesson-clip")
                Button("Remove Clip",role:.destructive){confirmRemoveClip()}.accessibilityIdentifier("lesson-remove-clip")
            }.disabled(controller.busy || controller.allLessons || controller.language=="en").onChange(of:controller.selectedLesson){clip=0}
            Button("Discard Translated Text…",role:.destructive){confirmDiscard()}.disabled(!controller.canDiscardTranslation)
            Button("Remove Outdated Translations…"){confirmPurge()}.disabled(controller.busy)
        }
        if !controller.inspection.isEmpty {
            Section("Translated text") {ScrollView{Text(controller.inspection).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}.frame(minHeight:Metrics.lessonInspectionMinimum,maxHeight:Metrics.lessonInspectionMaximum)}
        }
    }
    private var groups:[LessonGroup] {LessonLanguageController.groups(library)}
    /// The list's status columns. Their titles are hidden from VoiceOver, so each cell names its column and says a
    /// blank cell's meaning; nil is a status still being read.
    static let statusColumns=["Translated","Recorded","Out of Date"]
    static func statusCells(_ status:LessonStoredStatus?)->[(column:String,shown:String,spoken:String)] {
        guard let status else{return zip(statusColumns,["…","…",""]).map{($0,$1,"Loading")}}
        let translated=status.translated ? "Yes":"No"
        return zip(statusColumns,[(translated,translated),(status.recordedText,status.recordedText),(status.stale ? "Yes":"",status.stale ? "Yes":"No")]).map{($0,$1.0,$1.1)}
    }
    /// L-27: every lesson with what is stored for the chosen language and voice, grouped by course section, and its own
    /// Translate and Record.
    private var lessonList:some View {
        ScrollView {
            Grid(alignment:.leading,horizontalSpacing:Metrics.smallGap,verticalSpacing:Metrics.tightGap) {
                GridRow{Text("Lesson");ForEach(Self.statusColumns,id:\.self){Text($0)};Color.clear.gridCellUnsizedAxes([.horizontal,.vertical])}.font(.caption.bold()).foregroundStyle(.secondary).accessibilityHidden(true)
                ForEach(groups,id:\.lessons){group in
                    Text(group.title).sectionHeading(.caption.bold()).padding(.top,Metrics.tightGap).gridCellColumns(5)
                    ForEach(group.lessons,id:\.self){lessonRow($0)}
                }
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.frame(minHeight:Metrics.lessonInspectionMinimum,maxHeight:Metrics.lessonInspectionMaximum).accessibilityIdentifier("lesson-status-list")
    }
    private func lessonRow(_ index:Int)->some View {
        let lesson=library.lessons[index],status=controller.lessonStatuses.indices.contains(index) ? controller.lessonStatuses[index]:nil,idle = !controller.busy && !controller.planning
        return GridRow {
            Text(lesson.title).lineLimit(1).truncationMode(.tail)
            ForEach(Self.statusCells(status),id:\.column){cell in Text(cell.shown).accessibilityLabel(cell.column).accessibilityValue(cell.spoken).help(cell.column=="Out of Date" && status?.stale==true ? "A stored file for this lesson can no longer be used. Translate or record the lesson again, or remove what is stored.":"")}
            HStack(spacing:Metrics.tightGap) {
                Button("Translate"){confirmLesson(index,"translate")}.disabled(!idle || status==nil || status?.translated==true)
                    .accessibilityLabel("Translate \(lesson.title)").accessibilityIdentifier("lesson-row-translate-\(lesson.id)")
                Button("Record"){confirmLesson(index,"record")}.disabled(!idle || audioConflict || status?.translated != true || status?.recorded==status?.clips)
                    .accessibilityLabel("Record \(lesson.title)").accessibilityIdentifier("lesson-row-record-\(lesson.id)")
            }.controlSize(.small)
        }.accessibilityElement(children:.contain).accessibilityIdentifier("lesson-status-\(lesson.id)")
    }
    /// Every lesson is a long job billed to the learner's account: the sign-in is checked and the work counted first,
    /// and nothing is requested until the learner confirms the counts.
    private func confirmAll(_ mode:String){Task{@MainActor in run(await controller.planAll(mode:mode),mode)}}
    /// One lesson from the list goes through the same check and confirmation.
    private func confirmLesson(_ index:Int,_ mode:String){Task{@MainActor in run(await controller.plan(mode:mode,lesson:index),mode)}}
    private func run(_ plan:LessonJobPlan?,_ mode:String){
        guard let plan else{return}
        let alert=NSAlert();alert.messageText=plan.title;alert.informativeText=plan.message;alert.addButton(withTitle:plan.action);alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else{controller.declinePlan();return}
        if mode=="translate"{controller.translate()}else{controller.record()}
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
