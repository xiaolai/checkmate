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
            // Exercise AppKit's failed-entry callback without changing Spaces.
            game.windowWillEnterFullScreen(Notification(name:NSWindow.willEnterFullScreenNotification,object:window))
            game.windowDidFailToEnterFullScreen(window)
            window.contentView?.layoutSubtreeIfNeeded();sample("failed-fullscreen-restored")
            if game.split.view.constraints.contains(where:{$0.isActive && $0.firstAttribute == .width && abs($0.constant-window.screen!.frame.width)<1}){failures.append("Failed fullscreen left screen-width constraint active")}
            if abs(window.frame.width-initial.width)>1 || abs(window.frame.height-initial.height)>1{failures.append("Failed fullscreen restoration drift")}
            await toggle("before-fullscreen-left",left:true);await toggle("before-fullscreen-right",left:false)
            window.toggleFullScreen(nil);try? await Task.sleep(nanoseconds:2_000_000_000);sample("fullscreen-open-panes")
            if !window.styleMask.contains(.fullScreen){failures.append("Fullscreen did not enter with open panes")}
            window.toggleFullScreen(nil);try? await Task.sleep(nanoseconds:2_000_000_000);sample("fullscreen-restored-open-panes")
            await toggle("after-fullscreen-left-close",left:true);await toggle("after-fullscreen-right-close",left:false)
            if abs(window.frame.width-initial.width)>1 || abs(window.frame.height-initial.height)>1{failures.append("Fullscreen open-pane restoration drift")}
            for sample in samples {if let a=sample["titleCenter"] as? CGFloat,let b=sample["boardCenter"] as? CGFloat,abs(a-b)>1{failures.append("Title center drift at \(sample["phase"]!)")}}
            try? JSONSerialization.data(withJSONObject:["passed":failures.isEmpty,"failures":failures,"samples":samples],options:.prettyPrinted).write(to:URL(fileURLWithPath:directory+"/layout-results.json"))
        }
    }
}
