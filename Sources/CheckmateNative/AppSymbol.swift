import AppKit
import SwiftUI
/// Every SF Symbol the app draws, named by what it means (D-18). A raw value may appear once, so the compiler refuses
/// a second meaning for one symbol; views name the meaning and never a symbol string.
enum AppSymbol:String,CaseIterable {
    // Places
    case practice="flag.checkered",network,puzzles="puzzlepiece",training="figure.run",review="doc.text.magnifyingglass",unsavedReview="doc.badge.ellipsis",savedReview="doc.text"
    case lesson="book",gameActivity="gamecontroller",miniGame="gamecontroller.fill",exercise="target",allSavedReviews="list.bullet"
    // Marks
    case done="checkmark.circle.fill",solvedLater="checkmark.circle",toReview="arrow.uturn.backward.circle",continueHere="bookmark.fill",markerOff="circle",markerOn="largecircle.fill.circle",warning="exclamationmark.triangle.fill",limited="exclamationmark.circle",protection="link"
    case earlierPosition="clock.arrow.circlepath",search="magnifyingglass",habit="eye",imaginedLine="arrow.triangle.branch",moreActions="ellipsis.circle",expanded="chevron.down",collapsed="chevron.right"
    // Actions
    case continueLearning="arrow.forward.circle",hint="lightbulb",play="play.fill",pause="pause.fill",startOver="arrow.counterclockwise",undo="arrow.uturn.backward"
    case previous="chevron.backward",next="chevron.forward",previousLesson="chevron.backward.2",nextLesson="chevron.forward.2",replayFromStart="backward.end",firstPosition="backward.end.fill",lastPosition="forward.end.fill"
    case flipBoard="arrow.up.arrow.down",library="square.grid.2x2",microphone="mic",microphoneOff="mic.slash",stopSpeaking="stop.fill"
    // Window and settings
    case sidebar="sidebar.left",inspector="sidebar.right",settings="gearshape",board="checkerboard.rectangle",sound="speaker.wave.2",voice="waveform",connections="cable.connector",usage="chart.bar",about="info.circle"
    var image:Image {Image(systemName:rawValue)}
    func nsImage(_ description:String?=nil)->NSImage? {NSImage(systemSymbolName:rawValue,accessibilityDescription:description)}
}
extension Label where Title==Text,Icon==Image {
    init(_ title:String,symbol:AppSymbol){self.init(title,systemImage:symbol.rawValue)}
}
