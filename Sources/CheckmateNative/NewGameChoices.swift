import AppKit
import CheckmateCore

/// The New Game sheet's two choices (B-18): the learner's side, with Random Side, and the opponent's strength from
/// the same presets as the Opponent settings.
enum NewGameChoices {
    struct Choice:Equatable {let title:String,tag:String}
    static let sides=[Choice(title:"Play as White",tag:"w"),Choice(title:"Play as Black",tag:"b"),Choice(title:"Random Side",tag:"random")]
    /// The side the sheet's choice at `index` plays; Random Side asks `coin` (true is White).
    static func side(at index:Int,_ coin:()->Bool)->String {
        let tag=sides[max(0,min(sides.count-1,index))].tag;return tag=="random" ? (coin() ? "w":"b"):tag
    }
    static var strengths:[Choice] {
        (ReviewRolloutPolicy.beginnerOpponentEnabled ? [Choice(title:"First Steps",tag:"first_steps")]:[])+[Choice(title:"Gentle",tag:"gentle"),Choice(title:"Club",tag:"club"),Choice(title:"Keep Custom Settings",tag:"custom")]
    }
    /// The strength shown for the saved preset; one this build does not offer shows as Keep Custom Settings.
    static func strengthIndex(_ settings:AppSettings)->Int {
        let list=strengths;return list.firstIndex{$0.tag==settings.opponentPreset} ?? list.count-1
    }
    /// The sheet's accessory: a labelled pop-up for each choice, the side opening on `side`.
    @MainActor static func view(settings:AppSettings,side:String)->(view:NSView,side:NSPopUpButton,strength:NSPopUpButton) {
        func popUp(_ choices:[Choice],selected:Int,label:String)->NSPopUpButton {
            let button=NSPopUpButton(frame:NSRect(x:0,y:0,width:220,height:28));button.addItems(withTitles:choices.map(\.title));button.selectItem(at:selected);button.setAccessibilityLabel(label);return button
        }
        let sidePicker=popUp(sides,selected:side=="b" ? 1:0,label:"Your side"),strength=popUp(strengths,selected:strengthIndex(settings),label:"Opponent")
        let grid=NSGridView(views:[[NSTextField(labelWithString:"Your side:"),sidePicker],[NSTextField(labelWithString:"Opponent:"),strength]])
        grid.column(at:0).xPlacement = .trailing;grid.rowAlignment = .firstBaseline;grid.frame=NSRect(origin:.zero,size:grid.fittingSize)
        return (grid,sidePicker,strength)
    }
}
