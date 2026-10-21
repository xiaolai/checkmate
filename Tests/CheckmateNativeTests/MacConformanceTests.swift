import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import CheckmateNative
import CheckmateCore

/// The menu bar, the window and documents follow the Mac's own conventions (wave 3, Mac conformance).
@MainActor final class MacConformanceTests:XCTestCase {
    private var directory:URL!
    override func setUp(){directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);setenv("CHECKMATE_DATA_DIR",directory.path,1)}
    override func tearDown(){unsetenv("CHECKMATE_DATA_DIR");try? FileManager.default.removeItem(at:directory)}
    /// A model, its window and an app delegate with the menus installed; `body` runs before everything is put back.
    private func withMenus(_ body:(NativeModel,GameWindow,AppDelegate) throws -> Void) throws {
        let model=try NativeModel(),game=GameWindow(model:model),app=AppDelegate(),before=(NSApp.mainMenu,NSApp.helpMenu,NSApp.servicesMenu)
        defer{NSApp.mainMenu=before.0;NSApp.helpMenu=before.1;NSApp.servicesMenu=before.2;game.window?.delegate=nil;model.shutdown()}
        app.model=model;app.game=game;app.recents=RecentFiles.memory();app.installMenus(window:game,model:model)
        try body(model,game,app)
    }
    private func items(_ menu:NSMenu?)->[NSMenuItem] {(menu?.items ?? []).flatMap{[$0]+items($0.submenu)}}
    private func top(_ title:String)->NSMenu? {NSApp.mainMenu?.items.first{$0.title==title}?.submenu}
    private func item(_ title:String,in menu:String)->NSMenuItem? {top(menu)?.items.first{$0.title==title}}
    private func modifiers(_ item:NSMenuItem)->NSEvent.ModifierFlags {item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)}

    // D-2, D-3, D-1, D-8: the standard menus in the standard order; Data folds into File; Help and Services are the system's.
    func testMenusFollowTheStandardOrderWithHelpAndServices()throws {try withMenus{_,_,_ in
        XCTAssertEqual(NSApp.mainMenu?.items.dropFirst().map(\.title),["File","Edit","View","Game","Lesson","Window","Help"])
        XCTAssertNil(top("Data"),"Data folds into File")
        let help=try XCTUnwrap(top("Help"));XCTAssertTrue(NSApp.helpMenu===help,"menu search needs the system's Help menu")
        XCTAssertEqual(help.items.map(\.title),["Checkmate Help","Report a Problem"])
        XCTAssertEqual(item("Checkmate Help",in:"Help")?.keyEquivalent,"?")
        let app=try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu),services=try XCTUnwrap(app.items.first{$0.title=="Services"}?.submenu)
        // AppKit keeps the first Services menu it is given for the life of the process (the app installs menus once), so
        // a test that runs after another menu test sees that one; it is still the app's own Services submenu.
        XCTAssertEqual(services.title,"Services");XCTAssertEqual(NSApp.servicesMenu?.title,"Services")
        XCTAssertEqual(app.items.filter{!$0.isSeparatorItem}.map(\.title),["About Checkmate","Check for Updates…","Settings…","Services","Hide Checkmate","Hide Others","Show All","Quit Checkmate"])
    }}

    // D-3, D-7, R-14, R-15: File holds the documents and the progress items; Close (⌘W) lives here, not in Window.
    func testFileHoldsCloseExportShareRecentsAndProgress()throws {try withMenus{_,_,_ in
        let titles=try XCTUnwrap(top("File")).items.filter{!$0.isSeparatorItem}.map(\.title)
        XCTAssertEqual(titles,["Open…","Open Recent","Paste PGN or FEN","Close","Save Review","Export…","Share","Review Current Game","Review Previous Game","Import Progress…","Export Progress…","Show Backups…"])
        let close=try XCTUnwrap(item("Close",in:"File"));XCTAssertEqual(close.action,#selector(NSWindow.performClose(_:)));XCTAssertEqual(close.keyEquivalent,"w");XCTAssertEqual(modifiers(close),.command)
        let export=try XCTUnwrap(item("Export…",in:"File"));XCTAssertEqual(export.keyEquivalent,"e");XCTAssertEqual(modifiers(export),[.command,.shift])
        XCTAssertNotNil(item("Open Recent",in:"File")?.submenu)
        XCTAssertNil(item("Close",in:"Window"),"Close moved to File")
        XCTAssertEqual(top("Window")?.items.filter{!$0.isSeparatorItem}.map(\.title),["Minimize","Zoom","Bring All to Front"])
    }}

    // D-3: File ▸ Close (⌘W) reaches the window's close check, which quits through Quit's questions.
    func testCloseReachesTheWindowAndQuits()throws {try withMenus{_,game,_ in
        let close=try XCTUnwrap(item("Close",in:"File")),window=try XCTUnwrap(game.window),action=try XCTUnwrap(close.action);var quits=0
        XCTAssertTrue(window.delegate===game);XCTAssertTrue(window.styleMask.contains(.closable));game.quit={quits+=1}
        // AppKit's performClose plays the alert sound when the close is refused; the board window asks itself, silently.
        XCTAssertTrue(window is BoardWindow);let own=#selector(NSWindow.performClose(_:))
        XCTAssertNotEqual(BoardWindow.instanceMethod(for:own),NSWindow.instanceMethod(for:own),"Close would go through AppKit's refusal, which beeps")
        XCTAssertTrue(NSApp.sendAction(action,to:window,from:close),"⌘W is not delivered to the window")
        XCTAssertEqual(quits,1,"⌘W did not reach windowShouldClose")
    }}

    // D-4, D-5, D-8: Play leaves ⌘P free, the sidebar is ⌃⌘S, full screen is explicit, and no two items share a chord.
    func testShortcutsAreStandardAndUnique()throws {try withMenus{_,_,_ in
        let play=try XCTUnwrap(item("Play",in:"Lesson"));XCTAssertEqual(play.keyEquivalent,"p");XCTAssertEqual(modifiers(play),[.command,.option])
        for action in [ControlBarAction.playPause,.reviewPlayPause,.demoPlayPause]{XCTAssertEqual(ControlBarView.shortcut(action),"⌥⌘P","the bar's tooltip names the menu's chord")}
        let sidebar=try XCTUnwrap(top("View")?.items.first{$0.action == #selector(NSSplitViewController.toggleSidebar(_:))});XCTAssertEqual(sidebar.keyEquivalent,"s");XCTAssertEqual(modifiers(sidebar),[.command,.control])
        let details=try XCTUnwrap(top("View")?.items.first{$0.action == #selector(NSSplitViewController.toggleInspector(_:))});XCTAssertEqual(details.keyEquivalent,"i");XCTAssertEqual(modifiers(details),[.command,.option])
        let full=try XCTUnwrap(item("Enter Full Screen",in:"View"));XCTAssertEqual(full.action,#selector(NSWindow.toggleFullScreen(_:)));XCTAssertEqual(full.keyEquivalent,"f");XCTAssertEqual(modifiers(full),[.command,.control])
        func chord(_ item:NSMenuItem)->String {let key=item.keyEquivalent,shift=key != key.lowercased();return "\(item.keyEquivalentModifierMask.union(shift ? .shift:[]).intersection(.deviceIndependentFlagsMask).rawValue)-\(key.lowercased())"}
        let chords=items(NSApp.mainMenu).filter{!$0.keyEquivalent.isEmpty}.map(chord)
        XCTAssertEqual(chords.count,Set(chords).count,"a chord is used twice: \(chords.sorted())")
        XCTAssertFalse(chords.contains("\(NSEvent.ModifierFlags.command.rawValue)-p"),"⌘P stays free")
    }}

    // D-5, D-6: one noun per drawer, one source of truth for its title, and the system's toggle actions drive the drawers.
    func testDrawerTogglesShareOneTitleSource()throws {try withMenus{_,game,_ in
        XCTAssertEqual(GameWindow.drawerTitle(sidebar:true,open:false),"Show Sidebar");XCTAssertEqual(GameWindow.drawerTitle(sidebar:false,open:true),"Hide Details")
        let menuItem=NSMenuItem(title:"",action:#selector(NSSplitViewController.toggleInspector(_:)),keyEquivalent:"")
        game.desiredRight=false;XCTAssertTrue(game.split.validateUserInterfaceItem(menuItem));XCTAssertEqual(menuItem.title,"Show Details")
        game.split.toggleInspector(nil);XCTAssertTrue(game.desiredRight,"the system toggle opens the window's own drawer")
        XCTAssertTrue(game.split.validateUserInterfaceItem(menuItem));XCTAssertEqual(menuItem.title,"Hide Details")
        let sidebar=NSMenuItem(title:"",action:#selector(NSSplitViewController.toggleSidebar(_:)),keyEquivalent:"");let wasOpen=game.desiredLeft
        game.split.toggleSidebar(nil);XCTAssertNotEqual(game.desiredLeft,wasOpen)
        XCTAssertTrue(game.split.validateUserInterfaceItem(sidebar));XCTAssertEqual(sidebar.title,GameWindow.drawerTitle(sidebar:true,open:game.desiredLeft))
    }}

    // D-28: the system's sidebar and inspector items, no Settings gear.
    func testToolbarUsesTheSystemToggleItems()throws {try withMenus{_,game,_ in
        let toolbar=try XCTUnwrap(game.window?.toolbar),identifiers=game.toolbarDefaultItemIdentifiers(toolbar).map(\.rawValue)
        XCTAssertTrue(identifiers.contains(NSToolbarItem.Identifier.toggleSidebar.rawValue));XCTAssertTrue(identifiers.contains(NSToolbarItem.Identifier.toggleInspector.rawValue))
        XCTAssertFalse(identifiers.contains("checkmate.settings"));XCTAssertFalse(identifiers.contains("checkmate.sidebar"))
        let inspector=NSToolbarItem(itemIdentifier:.toggleInspector);game.label(toolbarItem:inspector)
        XCTAssertEqual(inspector.label,"Details");XCTAssertEqual(inspector.toolTip,GameWindow.drawerTitle(sidebar:false,open:game.desiredRight)+" (⌥⌘I)")
    }}

    // D-10: the window's title and subtitle name the activity, for the Window menu, Mission Control and VoiceOver.
    func testWindowTitleFollowsTheActivity()throws {try withMenus{_,game,_ in
        XCTAssertEqual(GameWindow.boardLabel(title:"Practice",subtitle:"White vs Stockfish"),"Practice · White vs Stockfish");XCTAssertEqual(GameWindow.boardLabel(title:"Game review",subtitle:""),"Game review")
        game.refresh();XCTAssertEqual(game.window?.title,"Practice");XCTAssertEqual(game.window?.subtitle,"White vs Stockfish");XCTAssertEqual(game.titleView.label.stringValue,"Practice · White vs Stockfish")
    }}

    // V-23: Settings is titled by its pane and draws a real titlebar over scrolled content; it stays findable by identifier.
    func testSettingsTitleFollowsThePane()throws {let model=try NativeModel();defer{model.shutdown()}
        let settings=SettingsWindow(model:model);settings.show(category:.sound);defer{settings.close()}
        XCTAssertEqual(settings.window?.title,"Sound");XCTAssertEqual(settings.window?.identifier?.rawValue,"Settings")
        settings.selectCategory(.about);XCTAssertEqual(settings.window?.title,"About")
        XCTAssertEqual(settings.window?.titlebarAppearsTransparent,false)
    }

    // D-9: About is the standard panel, with the acknowledgements in its credits.
    func testAboutUsesTheStandardPanelWithCredits()throws {try withMenus{_,_,app in
        var shown:[NSApplication.AboutPanelOptionKey:Any]?;app.presentAbout={shown=$0}
        let about=try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu?.items.first{$0.title=="About Checkmate"})
        XCTAssertEqual(about.action,#selector(AppDelegate.showAbout));XCTAssertTrue(about.target===app)
        app.showAbout()
        let credits=try XCTUnwrap(shown?[.credits] as? NSAttributedString).string
        for text in ["Stockfish 19","chess.js","GNU General Public License","Settings"]{XCTAssertTrue(credits.contains(text),"credits miss \(text)")}
    }}

    // D-1: Help explains the app, including that closing the window quits (D-7); Report a Problem opens the issue form.
    func testHelpAndReportAProblem()throws {try withMenus{model,_,app in
        XCTAssertTrue(HelpContent.sections.contains{$0.text.contains("Closing the window quits Checkmate")})
        app.showHelp();XCTAssertEqual(app.help?.window?.title,"Checkmate Help");app.help?.close()
        app.reportProblem()
        let log=try String(contentsOf:model.store.directory.appendingPathComponent("opened-urls.txt"),encoding:.utf8)
        XCTAssertTrue(log.contains("https://github.com/xiaolai/checkmate/issues/new"))
    }}

    // R-14: Copy FEN and Copy PGN copy what the board shows; Export and Share need a record.
    func testCopyFENAndPGNFromPractice()throws {try withMenus{model,_,app in
        let board=NSPasteboard(name:NSPasteboard.Name("checkmate-test-\(UUID().uuidString)"));defer{board.releaseGlobally()};app.pasteboard=board
        let copyFEN=try XCTUnwrap(item("Copy FEN",in:"Edit")),copyPGN=try XCTUnwrap(item("Copy PGN",in:"Edit")),export=try XCTUnwrap(item("Export…",in:"File"))
        XCTAssertTrue(app.validateMenuItem(copyFEN));XCTAssertFalse(app.validateMenuItem(copyPGN),"no moves yet");XCTAssertFalse(app.validateMenuItem(export))
        app.copyFEN();XCTAssertEqual(board.string(forType:.string),model.session.rules.fen)
        _ = try model.session.rules.move(uci:"e2e4")
        XCTAssertTrue(app.validateMenuItem(copyPGN));XCTAssertTrue(app.validateMenuItem(export))
        app.copyPGN();XCTAssertTrue(board.string(forType:.string)?.contains("1. e4") == true)
        XCTAssertTrue(app.shareMenuItem().isEnabled)
    }}

    // R-14: a network game copies nothing out, whatever the board shows (fairness).
    func testNothingIsCopiedOutOfANetworkGame() {
        XCTAssertNil(ShownRecord.make(mode:.network,fen:"8/8/8/8/8/8/8/K6k w - - 0 1",pgn:"1. e4"))
        XCTAssertEqual(ShownRecord.make(mode:.practice,fen:"f",pgn:"")?.pgn,nil,"an empty game has no PGN")
        XCTAssertNil(ShownRecord.make(mode:.lesson,fen:nil,pgn:nil))
    }

    // R-15: the Open panel offers PGN, FEN and plain text files.
    func testOpenPanelTypesCoverPGNFENAndText() {
        for ext in ["pgn","fen","txt"] {let type=UTType(filenameExtension:ext) ?? .data;XCTAssertTrue(ReviewFileTypes.openable.contains{type.conforms(to:$0)},"\(ext) is not offered")}
        XCTAssertFalse(ReviewFileTypes.openable.contains{UTType.png.conforms(to:$0)})
    }

    // R-15: opened files join Open Recent, which reopens them and can be cleared.
    func testOpenRecentListsOpenedFiles()throws {try withMenus{model,_,app in
        let missing=directory.appendingPathComponent("gone.pgn");app.recents.note(missing)
        let menu=try XCTUnwrap(item("Open Recent",in:"File")?.submenu);app.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.filter{!$0.isSeparatorItem}.map(\.title),["gone.pgn","Clear Menu"])
        app.openRecent(menu.items[0]);XCTAssertNotNil(model.storageError,"a missing recent file says so")
        app.clearRecents();app.menuNeedsUpdate(menu);XCTAssertEqual(menu.items.map(\.title),["Clear Menu"]);XCTAssertFalse(menu.items[0].isEnabled)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let file=directory.appendingPathComponent("game.pgn");try Data("1. e4 e5 *\n".utf8).write(to:file)
        // A file joins once it has been read, off the main thread.
        app.application(NSApp,open:[file]);let end=Date().addingTimeInterval(5);while app.recents.urls().isEmpty && Date()<end{RunLoop.main.run(until:Date().addingTimeInterval(0.02))}
        XCTAssertEqual(app.recents.urls().map(\.lastPathComponent),["game.pgn"])
    }}

    // V-19: updates are checked on request against the latest release; automatic checks are opt-in and never in tests.
    func testUpdateCheckerComparesTheLatestRelease() async {
        XCTAssertTrue(UpdateChecker.newer("1.10.0",than:"1.9.2"));XCTAssertFalse(UpdateChecker.newer("v2.0",than:"2.0.0"));XCTAssertFalse(UpdateChecker.newer("1.2.3",than:"1.3"))
        let release=Data(#"{"tag_name":"v9.9.9","html_url":"https://github.com/xiaolai/checkmate/releases/tag/v9.9.9"}"#.utf8)
        XCTAssertEqual(UpdateChecker.parse(release)?.version,"9.9.9")
        XCTAssertNil(UpdateChecker.parse(Data(#"{"tag_name":"v9","html_url":"https://example.com/x"}"#.utf8)),"a page outside the project is refused")
        let available=await UpdateChecker(fetch:{_ in release}).check(current:"1.0.0")
        XCTAssertEqual(available,.available(UpdateChecker.Release(version:"9.9.9",page:URL(string:"https://github.com/xiaolai/checkmate/releases/tag/v9.9.9")!)))
        let current=await UpdateChecker(fetch:{_ in release}).check(current:"9.9.9");XCTAssertEqual(current,.current("9.9.9"))
        let failed=await UpdateChecker(fetch:{_ in throw URLError(.notConnectedToInternet)}).check(current:"1.0.0");XCTAssertEqual(failed,.failed)
        do{_ = try await UpdateChecker.live.fetch(UpdateChecker.latest);XCTFail("tests never reach the network")}catch{}
    }
    func testAutomaticUpdateChecksAreOptIn()throws {
        XCTAssertFalse(AppSettings().checkForUpdates);XCTAssertFalse(AppSettings(raw:[:]).checkForUpdates)
        var on=AppSettings();on.checkForUpdates=true
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self,from:JSONEncoder().encode(on)).checkForUpdates,"the choice is saved")
        XCTAssertFalse(AppDelegate.checksAutomatically(settings:AppSettings(),silent:false))
        XCTAssertFalse(AppDelegate.checksAutomatically(settings:on,silent:true))
        XCTAssertTrue(AppDelegate.checksAutomatically(settings:on,silent:false))
    }
    func testCheckForUpdatesReportsTheResult() async throws {
        let model=try NativeModel(),app=AppDelegate();defer{model.shutdown()};app.model=model
        var alerts:[String]=[];app.presentUpdateAlert={alerts.append($0.messageText);return .alertSecondButtonReturn}
        app.updateChecker=UpdateChecker(fetch:{_ in Data(#"{"tag_name":"v99.0.0","html_url":"https://github.com/xiaolai/checkmate/releases/tag/v99.0.0"}"#.utf8)})
        await app.runUpdateCheck(automatic:false);XCTAssertEqual(alerts,["Checkmate 99.0.0 is available."])
        app.updateChecker=UpdateChecker(fetch:{_ in throw URLError(.timedOut)})
        await app.runUpdateCheck(automatic:true);XCTAssertEqual(alerts.count,1,"an automatic check that fails stays quiet")
        await app.runUpdateCheck(automatic:false);XCTAssertEqual(alerts.last,"Checkmate couldn’t check for updates.")
    }
}
