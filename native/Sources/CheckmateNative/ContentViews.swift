import SwiftUI
import CheckmateCore
struct SidebarContent:View {
    @ObservedObject var session:GameSession
    @ObservedObject var learning:LearningPlayer
    @ObservedObject var model:NativeModel
    // The open saved review's own row is selected; an unsaved review has no row.
    private var selected:String {model.review.active ? model.review.document.map{"review:"+$0.id.uuidString} ?? "review":session.mode == .practice ? "practice":session.mode == .puzzles ? "puzzles":"lesson:\(learning.lessonIndex)"}
    var body:some View {List(selection:Binding<String?>(get:{selected},set:{value in guard let value=value else{return};if value=="review"{model.pasteReview()}else if value.hasPrefix("review:"),let id=UUID(uuidString:String(value.dropFirst(7))){model.openSavedReview(id)}else if value=="practice"{model.practice()}else if value=="puzzles"{model.puzzles()}else if let i=Int(value.replacingOccurrences(of:"lesson:",with:"")){model.lesson(i)}})){
        Section {
            Label("Practice a game",systemImage:"flag.checkered").tag("practice")
            Label("Quick puzzles",systemImage:"lightbulb").tag("puzzles")
            Button("Review current game"){model.reviewCurrent()}
            Button("Open PGN…"){model.openPGN()}
            Button("Paste PGN or FEN"){model.pasteReview()}
        }
        Section("Saved reviews"){ForEach(model.reviews){record in Label(record.title,systemImage:"doc.text").tag("review:"+record.id.uuidString)}}
        Section("Learn & explore") {ForEach(Array(learning.library.lessons.enumerated()),id:\.element.id){i,l in Label {Text(l.title)} icon:{Image(systemName:session.state.course.completed.contains(l.id) ? "checkmark.circle.fill":"book")}.tag("lesson:\(i)")}}
    }.listStyle(.sidebar).scrollContentBackground(.hidden).overlay(alignment:.bottom){if model.importingReview{VStack{ProgressView("Importing review…");Button("Cancel import"){model.cancelReviewImport()}}.padding().background(.regularMaterial)}}}
}
struct DetailContent:View {
    @ObservedObject var session:GameSession
    @ObservedObject var learning:LearningPlayer
    @ObservedObject var model:NativeModel
    @ObservedObject var voice:VoiceCoach
    @ObservedObject var relationships:RelationshipController
    let inspect:(RelationshipMode)->Void
    var body:some View {ScrollView {VStack(alignment:.leading,spacing:Metrics.sectionGap) {
        if model.review.active{ReviewDetailContent(review:model.review,model:model)}else {
        if let label=relationships.selectedLabel{RelationshipContent(relationships:relationships,label:label,inspect:inspect);Divider()}
        if session.mode == .practice {
            if relationships.report==nil {
            if !session.presentationHidden,let d=session.demonstration {
                Text(d.title).font(.title2.bold());Text("Imagined moves").foregroundStyle(.secondary)
                Picker("Line",selection:Binding(get:{d.line},set:{try? session.seekDemo(line:$0,ply:0)})){ForEach(d.lines.indices,id:\.self){i in Text(d.lines[i].label).tag(i)}}
                Text(d.lines[d.line].frames[d.ply].explanation)
                Text("\(d.ply) / \(d.lines[d.line].frames.count-1)").foregroundStyle(.secondary)
            } else if !session.presentationHidden,let p=session.preview {
                Text("Try a move").font(.title2.bold());Text("This does not change your game.").foregroundStyle(.secondary)
                if let candidate=p.candidate {Text(candidate.description)}else{Text("Select a piece, then a destination to test your idea.")}
                if let e=p.evaluation {Text(e.comparison);Picker("Continuation",selection:Binding(get:{p.line},set:{try? session.previewAt(ply:0,line:$0)})){Text("Your move").tag("candidate");Text("Engine suggestion").tag("recommended")};Text(e.exchange.moves.joined(separator:" · "));Button("Play my move"){try? session.playCandidate()}}
                if p.status=="analyzing"{ProgressView("Comparing moves…")};if let error=p.error{Text(error).foregroundStyle(.secondary)}
            } else {
                if session.explicitResumeRequired {Text("Game paused.").font(.title2.bold());Text(session.message);Text("Your game is paused because a saved review could not be restored.");Button("Return to game"){model.resumeAfterFailedRestore()}}
                else {Text("Your next move.").font(.title2.bold());Text(session.message)}
                if session.pausedOpponent {Text("The companion opponent disconnected.");Button("Continue with Stockfish"){model.companion.disable();session.continueWithStockfish()}}
                OpponentSettingsContent(session:session)
                Text("Moves").font(.headline);Text(session.rules.history.isEmpty ? "Your story starts with one move.":session.rules.history.enumerated().map{($0.offset%2==0 ? "\($0.offset/2+1). ":"")+$0.element}.joined(separator:"  ")).textSelection(.enabled)
            }
            }
            if voice.connected || !voice.history.isEmpty {Divider();Text("Voice coach").font(.headline);Text(voice.status).foregroundStyle(.secondary);if voice.connected{HStack{Button("Recheck"){voice.recheck()};Button("Stop speaking"){voice.stopTurn()}}};ForEach(Array(voice.history.reversed())){entry in VStack(alignment:.leading){Text(entry.role=="learner" ? "You":"Coach").font(.caption).foregroundStyle(.secondary);Text(entry.text).textSelection(.enabled)}}}
            if let error=session.error {Text(error).foregroundStyle(Color(nsColor:NativeColors.error));Button("Retry Stockfish"){session.retryEngine()}}
        } else if relationships.report==nil {
            if learning.mini {
                Text(learning.miniStatus).font(.title2.bold())
                if !learning.miniKind.solo {
                    Picker("Opponent",selection:Binding(get:{learning.miniGame?.computer ?? true},set:{learning.setMiniComputer($0)})){Text("Computer").tag(true);Text("Two players on this device").tag(false)}
                    Picker("Difficulty",selection:Binding(get:{session.state.settings.miniOpponentProfile},set:{var settings=session.state.settings;settings.miniOpponentProfile=$0;session.updateSettings(settings)})){Text("Beginner").tag("beginner");Text("Standard").tag("standard");Text("Challenging").tag("challenging")}
                    Text(learning.miniGame?.computer==true ? "You play White. Select a piece, then its destination. The computer plays Black.":"Take turns moving White and Black on this device.")
                }
                Text(learning.miniKind.rules).foregroundStyle(.secondary)
                if !learning.feedback.isEmpty{Text(learning.feedback)}
            }
            else if learning.activePuzzle != nil || session.mode == .lesson {
                if session.mode == .lesson {
                    Picker("Transcript",selection:Binding(get:{learning.step},set:{learning.seek(step:$0)})){ForEach(learning.current.beats.indices,id:\.self){i in Text("\(i+1). \(learning.library.stepTitles[learning.lessonIndex][i])").tag(i)}}
                        .labelsHidden()
                    Text(learning.beat.say).textSelection(.enabled)
                } else {
                    if let prompt=learning.exercise?.prompt {Text(prompt).font(.title2.bold())}
                    Text(learning.activePuzzle?.context ?? learning.beat.say).textSelection(.enabled)
                }
                if let e=learning.exercise {
                    if e.kind=="choice" {ForEach(e.choices ?? [],id:\.self){choice in Button(choice){learning.choose(choice)}.disabled(learning.passed)}}
                    if e.kind=="squares" {if e.answers?.count != 1{Button("Check my answer"){learning.checkAnswer()}.disabled(learning.picked.isEmpty || learning.passed)};if e.allowNone==true{Button("No squares"){learning.noSquares()}.disabled(learning.passed)}}
                    if e.kind=="path"{Button("Restart path"){learning.restartPath()}}
                    Button(learning.activePuzzle==nil ? "Show the explanation":"Reveal answer"){learning.reveal()}.disabled(learning.passed)
                }
                if !learning.feedback.isEmpty{Text(learning.feedback).foregroundStyle(.secondary)}
                if session.mode == .lesson {
                    DisclosureGroup("In this lesson"){ForEach(learning.current.teaches ?? [],id:\.self){Text($0)}}
                    ForEach(MiniGameKind.available(lessonID:learning.current.id),id:\.self){kind in Button("Play \(kind.title)"){learning.startMini(kind)}}
                    if session.state.course.completed.contains(learning.current.id),learning.lessonIndex<learning.library.lessons.count-1 {Button("Continue to \(learning.library.lessons[learning.lessonIndex+1].title)"){model.lesson(learning.lessonIndex+1)}}
                } else {Button("Next puzzle"){learning.next()}.disabled(!learning.passed)}
            } else {Text("Quick puzzles").font(.title2.bold());Text("Choose an exercise from the library.")}
        }
    }
    }.frame(maxWidth:.infinity,alignment:.leading).padding(Metrics.sectionGap)}}
}
/// Import, storage, export and practice-fork failures, rendered over the board area so they
/// are visible whichever drawers are open. Dismiss clears the message.
struct StorageErrorBanner:View {
    @ObservedObject var model:NativeModel
    var body:some View {
        if let message=model.storageError {
            HStack(alignment:.top,spacing:Metrics.smallGap){
                Image(systemName:"exclamationmark.triangle.fill").foregroundStyle(Color(nsColor:NativeColors.error)).accessibilityHidden(true)
                Text(message).textSelection(.enabled).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("storage-error-message")
                Spacer(minLength:0)
                if model.restoreResumePending {Button("Return to game"){model.resumeAfterFailedRestore()}}
                Button("Dismiss"){model.dismissStorageError()}
            }
            .padding(Metrics.padding).background(.regularMaterial,in:RoundedRectangle(cornerRadius:8)).padding(Metrics.padding)
            .accessibilityElement(children:.contain).accessibilityLabel("Problem").accessibilityIdentifier("storage-error-banner")
        }
    }
}
struct TurnIndicator:View {
    let side:String,label:String
    var body:some View {Circle().fill(Color(nsColor:side=="w" ? BoardPalette.lightPiece:BoardPalette.darkPiece)).overlay(Circle().stroke(Color(nsColor:NativeColors.secondaryText),lineWidth:Metrics.turnIndicatorOutline)).frame(width:Metrics.turnIndicatorSize,height:Metrics.turnIndicatorSize).help(label).accessibilityLabel(label)}
}
struct TransportContent:View {
    @ObservedObject var session:GameSession
    @ObservedObject var learning:LearningPlayer
    @ObservedObject var voice:VoiceCoach
    @ObservedObject var review:ReviewController
    let newGame:()->Void,showDetails:()->Void
    /// Explicit resume for a reply held after a failed review entry; always reachable with both drawers closed.
    var resumeGame:()->Void={}
    var body:some View {HStack(spacing:Metrics.smallGap) {
        if review.active{ReviewTransport(review:review)}else if session.mode == .practice {
            if !session.presentationHidden,let d=session.demonstration {
                NativeIcon(symbol:"arrow.left",label:"Previous imagined move"){try? session.seekDemo(line:d.line,ply:max(0,d.ply-1))}.disabled(d.ply==0)
                NativeIcon(symbol:d.playing ? "pause.fill":"play.fill",label:d.playing ? "Pause demonstration":"Play demonstration"){d.playing ? session.pauseDemo():session.playDemo()}
                NativeIcon(symbol:"arrow.right",label:"Next imagined move"){try? session.seekDemo(line:d.line,ply:min(d.lines[d.line].frames.count-1,d.ply+1))}
                NativeIcon(symbol:"xmark",label:"Close demonstration"){session.closePresentation()}
            } else if !session.presentationHidden,let p=session.preview {
                NativeIcon(symbol:"arrow.left",label:"Previous preview move"){try? session.previewAt(ply:max(0,p.ply-1),line:p.line)}.disabled(p.evaluation==nil)
                NativeIcon(symbol:"arrow.right",label:"Next preview move"){let count=p.line=="candidate" ? p.evaluation?.candidateFrames.count:p.evaluation?.recommendedFrames.count;try? session.previewAt(ply:min((count ?? 1)-1,p.ply+1),line:p.line)}.disabled(p.evaluation==nil)
                NativeIcon(symbol:"xmark",label:"Return to game"){session.closePresentation()}
            } else {
                TurnIndicator(side:session.rules.turn,label:session.rules.status)
                if session.explicitResumeRequired {NativeIcon(symbol:"play.fill",label:"Resume game",action:resumeGame)}
                NativeIcon(symbol:"arrow.counterclockwise",label:"New game",action:newGame)
                NativeIcon(symbol:"arrow.uturn.backward",label:"Undo"){session.undo()}.disabled(session.rules.history.isEmpty)
                NativeIcon(symbol:"flask",label:"Try a move"){try? session.beginPreview()}.disabled(session.rules.turn != session.humanSide || session.rules.over || session.busyReason == "opponent")
                NativeIcon(symbol:"lightbulb",label:"Hint"){session.hint()}.disabled(session.busy || session.rules.turn != session.humanSide)
                if session.busy {ProgressView().controlSize(.small).help("Stockfish is thinking")}
            }
            if voice.connecting {
                ProgressView().controlSize(.small).help(voice.status).accessibilityLabel(voice.status)
                NativeIcon(symbol:"xmark",label:"Cancel voice connection"){voice.disconnect()}
            } else if voice.connected {
                NativeIcon(symbol:session.state.settings.voiceMicrophone ? "mic":"mic.slash",label:session.state.settings.voiceMicrophone ? "Mute microphone":"Enable microphone"){
                    var settings=session.state.settings
                    settings.voiceMicrophone.toggle()
                    session.updateSettings(settings)
                }
                NativeIcon(symbol:"stop.fill",label:"Stop coach speaking"){voice.stopTurn()}
                    .disabled(!voice.status.hasPrefix("Speaking") && voice.status != "Coach is thinking…")
                NativeIcon(symbol:"power",label:"Disconnect voice coach"){voice.disconnect()}
            } else {
                NativeIcon(symbol:"mic",label:session.companionEnabled ? "Disconnect the MCP companion before connecting voice":"Connect voice coach"){voice.connect()}
                    .disabled(session.companionEnabled)
            }
        } else if learning.mini {
            if !learning.miniKind.solo {TurnIndicator(side:learning.miniTurn,label:learning.miniStatus)}
            NativeIcon(symbol:"arrow.counterclockwise",label:"New game",action:newGame)
            NativeIcon(symbol:"arrow.uturn.backward",label:"Undo turn"){learning.undoMini()}.disabled(learning.miniGame?.history.isEmpty != false)
            NativeIcon(symbol:"arrow.left",label:"Back to lesson"){learning.leaveMini()}
        } else if session.mode == .lesson {
            NativeIcon(symbol:"book",label:"Show lesson guidance",action:showDetails)
            NativeIcon(symbol:"arrow.left",label:"Previous transcript"){learning.seek(step:learning.step-1)}.disabled(learning.step==0)
            NativeIcon(symbol:learning.playing ? "pause.fill":"play.fill",label:learning.playing ? "Pause":"Play"){learning.playing ? learning.pause():learning.play()}
            NativeIcon(symbol:"arrow.counterclockwise",label:"Replay transcript"){learning.replay()}
            NativeIcon(symbol:"arrow.right",label:"Next transcript"){learning.next()}.disabled(learning.exercise != nil && !learning.passed)
        } else if learning.activePuzzle != nil {
            NativeIcon(symbol:"square.grid.2x2",label:"Puzzle library"){learning.showPuzzleLibrary()}
            NativeIcon(symbol:"book",label:"Show puzzle question",action:showDetails)
            NativeIcon(symbol:"arrow.right",label:"Next puzzle"){learning.next()}.disabled(!learning.passed)
        }
    }.padding(Metrics.padding)}
}
// A passive edge indicator keeps playback feedback out of the transport controls.
struct LessonProgressContent:View {
    @ObservedObject var review:ReviewController
    @ObservedObject var session:GameSession
    @ObservedObject var learning:LearningPlayer
    @State private var color=NativeColors.playbackAccents.randomElement() ?? NSColor.controlAccentColor
    private var fraction:Double {if review.active{if let branch=review.branch{return branch.moves.isEmpty ? 0:Double(review.branchPly)/Double(branch.moves.count)};let route=[0]+(review.document?.mainline ?? []);return route.count<=1 ? 0:Double(route.firstIndex(of:review.nodeID) ?? 0)/Double(route.count-1)};return learning.duration>0 ? min(1,max(0,learning.seconds/learning.duration)):0}
    var body:some View {
        if review.active || session.mode == .lesson && !learning.mini && learning.activePuzzle==nil {
            GeometryReader {geometry in
                Rectangle().fill(Color(nsColor:color)).frame(width:geometry.size.width*fraction,height:Metrics.playbackLineHeight)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(review.active ? "Review playback":"Transcript playback")
            .accessibilityValue("\(Int(fraction*100)) percent")
        }
    }
}
struct PuzzleLibraryContent:View {
    @ObservedObject var learning:LearningPlayer
    @ObservedObject var session:GameSession
    var body:some View {VStack(alignment:.leading,spacing:Metrics.padding){Text("Quick puzzles").font(.largeTitle.bold());Text("\(session.state.puzzles.values.filter(\.solved).count) solved · \(session.state.puzzles.values.filter(\.review).count) to review").foregroundStyle(.secondary)
        TextField("Search exercises",text:$learning.query).textFieldStyle(.roundedBorder)
        HStack {Picker("Topic",selection:$learning.topic){Text("All topics").tag("All topics");ForEach(Array(Set(learning.library.puzzles.map(\.topic))).sorted(),id:\.self){Text($0).tag($0)}};Picker("Level",selection:$learning.level){ForEach(["All levels","Foundation","Developing"],id:\.self){Text($0).tag($0)}};Picker("Status",selection:$learning.filter){ForEach(["All","Unsolved","To review"],id:\.self){Text($0).tag($0)}}}
        Text("\(learning.filteredPuzzles.count) exercises").foregroundStyle(.secondary)
        List(learning.filteredPuzzles,id:\.id){p in Button{learning.openPuzzle(id:p.id)}label:{HStack{VStack(alignment:.leading){Text(p.title);Text(p.topic).font(.caption).foregroundStyle(.secondary)};Spacer();if session.state.puzzles[p.id]?.solved==true{Image(systemName:"checkmark.circle.fill").foregroundStyle(Color(nsColor:NativeColors.success))}}}.buttonStyle(.plain)}
        if learning.filteredPuzzles.isEmpty{Text("No exercises match these filters.")}
    }.padding(Metrics.sectionGap)}
}
struct WelcomeContent:View {let title:String,goals:[String];var body:some View {VStack(spacing:Metrics.sectionGap){Image("LessonKnight",bundle:.main).resizable().renderingMode(.template).scaledToFit().foregroundStyle(.primary).frame(width:Metrics.mascotSize,height:Metrics.mascotSize).accessibilityHidden(true);Text(title).font(.largeTitle.bold())}.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.center)}}
