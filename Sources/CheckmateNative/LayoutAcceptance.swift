import AppKit
import CheckmateCore
extension AppDelegate {
    func runLayoutAcceptance(directory:String){guard let game=game,let window=game.window else{return};try? FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
        Task {
            try? await Task.sleep(nanoseconds:500_000_000)
            var samples:[[String:Any]]=[],failures:[String]=[]
            @MainActor func sample(_ phase:String){window.contentView?.layoutSubtreeIfNeeded();game.titleView.layoutSubtreeIfNeeded();game.titleView.syncCenter();let core=game.main.view.convert(game.main.view.bounds,to:nil),board=game.board.boardRect,title=game.titleView.convert(game.titleView.label.frame,to:nil);let panes=[game.navigation!,game.inspector!].map{$0.view.convert($0.view.bounds,to:nil)}
                samples.append(["phase":phase,"window":[window.frame.minX,window.frame.minY,window.frame.width,window.frame.height],"main":[core.minX,core.minY,core.width,core.height],"boardSide":board.width,"titleCenter":title.midX,"boardCenter":core.midX,"leftCollapsed":game.sidebarItem.isCollapsed,"rightCollapsed":game.inspectorItem.isCollapsed,"paneHeights":panes.map(\.height)])
            }
            @MainActor func toggle(_ phase:String,left:Bool) async {left ? game.toggleLeft():game.toggleRight();for i in 0..<24{try? await Task.sleep(nanoseconds:33_000_000);sample(phase+"-"+String(i))}}
            let screen=window.screen!.visibleFrame,initial=window.frame
            for leftFirst in [true,false] {
                await toggle("normal-\(leftFirst)-first-open",left:leftFirst);await toggle("normal-\(leftFirst)-second-open",left:!leftFirst);await toggle("normal-\(leftFirst)-first-close",left:leftFirst);await toggle("normal-\(leftFirst)-second-close",left:!leftFirst)
                if abs(window.frame.width-initial.width)>1 || abs(game.main.view.frame.width-initial.width)>1{failures.append("Normal endpoints drift")}
            }
            for width in [CGFloat(1280),CGFloat(1000)] {
                let viewport=NSRect(x:screen.midX-width/2,y:screen.minY,width:width,height:min(900,screen.height));game.availableFrameOverride=viewport
                game.setCoreFrame(NSRect(x:viewport.minX,y:viewport.minY,width:Metrics.core,height:Metrics.core))
                for (phase,left) in [("left-open",true),("right-open",false),("left-close",true),("right-close",false)] {await toggle("constrained-\(Int(width))-"+phase,left:left);if phase=="right-open"{try? await game.capture(directory+"/constrained-\(Int(width))-both.png")};if !viewport.insetBy(dx:-1,dy:-1).contains(window.frame){failures.append("Window escaped constrained viewport \(width): \(NSStringFromRect(window.frame))")}}
                if abs(window.frame.width-window.frame.height)>1{failures.append("Constrained closed window not square")}
                try? await game.capture(directory+"/constrained-\(Int(width)).png")
            }
            game.availableFrameOverride=nil;game.setCoreFrame(initial)
            // The control bar at every board size, in the modes with the widest bars: each control inside the bar and
            // none overlapping another, the board square, and the rows the bar took. Both drawers are closed here.
            var bars:[[String:Any]]=[]
            if let model {
                let castling=model.learning.library.lessons.firstIndex{$0.id=="castling"} ?? 0,rook=model.learning.library.lessons.firstIndex{$0.id=="rook"} ?? 0
                let modes:[(String,()->Void)]=[("practice",{model.practice();model.session.cancelWork()}),("lesson",{model.lesson(rook);model.learning.pause();model.learning.seek(step:0)}),("exercise",{model.lesson(castling);model.learning.pause();model.learning.goToAttempt()})]
                for (mode,enter) in modes {
                    game.setCoreFrame(initial);enter();try? await Task.sleep(nanoseconds:300_000_000)
                    // Entering a lesson opens its guidance; close both drawers so the window is the board area alone.
                    if !game.sidebarItem.isCollapsed{await toggle("bar-\(mode)-close-left",left:true)}
                    if !game.inspectorItem.isCollapsed{await toggle("bar-\(mode)-close-right",left:false)}
                    for side in [CGFloat(780),600,480,320] {
                        game.setCoreFrame(NSRect(x:screen.minX+40,y:screen.minY+40,width:side,height:side));game.refresh()
                        try? await Task.sleep(nanoseconds:600_000_000);window.contentView?.layoutSubtreeIfNeeded()
                        let bar=CGRect(origin:.zero,size:game.controls.bounds.size),found=game.barFrames.sorted{$0.key<$1.key}.map{($0.key,$0.value)}
                        let phase="bar-\(mode)-\(Int(side))",board=game.board.boardRect
                        bars.append(["phase":phase,"window":[window.frame.width,window.frame.height],"barRows":Int(((game.controlsHeight.constant-Metrics.header)/(ControlBarView.rowHeight+Metrics.smallGap)).rounded())+1,"barControls":found.map{[$0.0,$0.1.minX,$0.1.minY,$0.1.width,$0.1.height]},"boardSide":board.width])
                        if found.count<4{failures.append("\(phase): the bar laid out only \(found.count) controls")}
                        for (label,frame) in found where !bar.insetBy(dx:-1,dy:-1).contains(frame){failures.append("\(phase): \(label) lies outside the bar \(NSStringFromRect(bar)): \(NSStringFromRect(frame))")}
                        for i in found.indices{for j in found.indices where j>i && found[i].1.insetBy(dx:1,dy:1).intersects(found[j].1.insetBy(dx:1,dy:1)){failures.append("\(phase): \(found[i].0) overlaps \(found[j].0)")}}
                        if abs(board.width-board.height)>1{failures.append("\(phase): the board is not square")}
                        // Below the usual minimum (only screens too small for it) the bar's own width can hold the window
                        // wider than asked, but the window stays square; at the minimum and above it is exactly the size asked.
                        if abs(window.frame.width-window.frame.height)>1 || side>=Metrics.minimum && abs(window.frame.width-side)>1{failures.append("\(phase): the window is \(NSStringFromRect(window.frame)) for a \(Int(side)) side")}
                        if side>=Metrics.minimum && game.titleView.window==nil{failures.append("\(phase): the title left the title bar")}
                        // The title stays centred over the board wherever the title bar holds it.
                        if side>=Metrics.minimum{sample("bar-\(mode)-side\(Int(side))")}
                        if side==600 || side==320{try? await game.capture(directory+"/\(phase).png")}
                    }
                }
                model.practice();try? await Task.sleep(nanoseconds:300_000_000)
                if !game.sidebarItem.isCollapsed{await toggle("bar-restore-close-left",left:true)}
                if !game.inspectorItem.isCollapsed{await toggle("bar-restore-close-right",left:false)}
                game.setCoreFrame(initial);try? await Task.sleep(nanoseconds:600_000_000)
            }
            // Exercise AppKit's failed-entry callback without changing Spaces.
            game.windowWillEnterFullScreen(Notification(name:NSWindow.willEnterFullScreenNotification,object:window))
            game.windowDidFailToEnterFullScreen(window)
            window.contentView?.layoutSubtreeIfNeeded();sample("failed-fullscreen-restored")
            if game.split.view.constraints.contains(where:{$0.isActive && $0.firstAttribute == .width && abs($0.constant-window.screen!.frame.width)<1}){failures.append("Failed fullscreen left screen-width constraint active")}
            if abs(window.frame.width-initial.width)>1 || abs(window.frame.height-initial.height)>1{failures.append("Failed fullscreen restoration drift: \(NSStringFromRect(window.frame)) vs \(NSStringFromRect(initial))")}
            await toggle("before-fullscreen-left",left:true);await toggle("before-fullscreen-right",left:false)
            window.toggleFullScreen(nil);try? await Task.sleep(nanoseconds:2_000_000_000);sample("fullscreen-open-panes")
            if !window.styleMask.contains(.fullScreen){failures.append("Fullscreen did not enter with open panes")}
            window.toggleFullScreen(nil);try? await Task.sleep(nanoseconds:2_000_000_000);sample("fullscreen-restored-open-panes")
            await toggle("after-fullscreen-left-close",left:true);await toggle("after-fullscreen-right-close",left:false)
            if abs(window.frame.width-initial.width)>1 || abs(window.frame.height-initial.height)>1{failures.append("Fullscreen open-pane restoration drift: \(NSStringFromRect(window.frame)) vs \(NSStringFromRect(initial))")}
            for sample in samples {if let a=sample["titleCenter"] as? CGFloat,let b=sample["boardCenter"] as? CGFloat,abs(a-b)>1{failures.append("Title center drift at \(sample["phase"]!)")}}
            try? JSONSerialization.data(withJSONObject:["passed":failures.isEmpty,"failures":failures,"samples":samples,"bar":bars],options:.prettyPrinted).write(to:URL(fileURLWithPath:directory+"/layout-results.json"))
        }
    }
}
