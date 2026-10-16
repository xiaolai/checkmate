import XCTest
import AppKit
@testable import CheckmateNative
import CheckmateCore
@testable import CheckmateApplication

/// The library table: its update plan as a pure function, and a real (windowless) table driven by its coordinator.
@MainActor final class LibraryTableTests:XCTestCase {
    private func row(_ id:String,_ title:String="Game")->LibraryListItem {
        .row(LibraryRow(id:id,source:.collection(sha256:"s",record:CollectionRecord(offset:0,length:1,sha256:"h",tags:[:])),title:title,details:"",result:"*",facts:nil,accessibilityLabel:title,searchKey:""))
    }
    private func header(_ id:String,_ title:String="Section")->LibraryListItem {.header(LibrarySection(id:id,title:title,kind:.classics,rows:[]))}

    func testUnchangedLinesNeedNothing() {
        let lines=[header("a"),row("1"),row("2")]
        XCTAssertEqual(LibraryTableUpdate.plan(old:lines,new:lines),.none)
        XCTAssertEqual(LibraryTableUpdate.plan(old:[],new:[]),.none)
    }
    func testAReorderReloads() {
        XCTAssertEqual(LibraryTableUpdate.plan(old:[header("a"),row("1"),header("b"),row("2"),row("3")],new:[header("b"),row("2"),row("3"),header("a"),row("1")]),.reload)
    }
    func testRemovalsUseOldIndexesAndInsertionsFinalOnes() {
        let old=[header("a"),row("1"),row("2"),row("3"),header("b"),row("4"),row("5"),row("6")]
        let new=[header("a"),row("1"),row("3"),row("9"),header("b"),row("4"),row("5"),row("6")]
        // "2" was at old index 2; "9" is at final index 3.
        XCTAssertEqual(LibraryTableUpdate.plan(old:old,new:new),.patch(removed:IndexSet([2]),inserted:IndexSet([3]),changed:IndexSet()))
    }
    func testAContentChangeReloadsAtItsFinalIndex() {
        let old=[header("a"),row("1"),row("2"),row("3"),row("4")],new=[header("a"),row("0"),row("1"),row("2","Renamed"),row("3"),row("4")]
        XCTAssertEqual(LibraryTableUpdate.plan(old:old,new:new),.patch(removed:IndexSet(),inserted:IndexSet([1]),changed:IndexSet([3])))
    }

    /// A real table through its coordinator: after an update that renames one collection, drops another and adds a
    /// third, the rows are in order, show the new text, keep their group-row flags and the selection, and a refreshed
    /// row opens the new game. The table needs no window.
    func testTheCoordinatorAppliesAnUpdateToARealTable() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("library-table-\(UUID().uuidString)");defer{try? FileManager.default.removeItem(at:folder)}
        func collection(_ sha:String,_ name:String,_ count:Int)->CollectionIndex {
            CollectionIndex(schemaVersion:1,sha256:sha,name:name,bytes:10,importedAt:Date(timeIntervalSince1970:Double(sha.count)),
                            records:(0..<count).map{CollectionRecord(offset:$0,length:1,sha256:"h",tags:["White":"W\($0)","Black":"B\($0)"])},unreadable:0)
        }
        let one=String(repeating:"1",count:64),two=String(repeating:"2",count:64),three=String(repeating:"3",count:64)
        let library=ReviewLibraryController(directory:folder)
        library.publish(LibraryCatalog(library:nil,collections:[collection(one,"One",2),collection(two,"Two",1)]))
        let coordinator=LibraryTable.Coordinator(library),table=LibraryTable.makeTable(coordinator);table.frame=NSRect(x:0,y:0,width:400,height:600)
        coordinator.apply(focusRequests:0)
        XCTAssertEqual(table.appliedIDs,["header:collection:"+one,"collection:\(one):0","collection:\(one):1","header:collection:"+two,"collection:\(two):0"])
        library.selection="collection:\(one):1";coordinator.apply(focusRequests:0);XCTAssertEqual(table.selectedRow,2)
        let shown=try XCTUnwrap(table.view(atColumn:0,row:2,makeIfNecessary:true) as? GameRowCell);XCTAssertEqual(shown.boundRow?.details,"One")

        library.publish(LibraryCatalog(library:nil,collections:[collection(one,"Uno",2),collection(three,"Three",1)]))
        coordinator.apply(focusRequests:0)
        XCTAssertEqual(table.appliedIDs,["header:collection:"+one,"collection:\(one):0","collection:\(one):1","header:collection:"+three,"collection:\(three):0"])
        XCTAssertEqual(table.appliedVersion,library.shownVersion);XCTAssertEqual(table.numberOfRows,5)
        XCTAssertEqual((0..<5).map{coordinator.tableView(table,isGroupRow:$0)},[true,false,false,true,false])
        XCTAssertEqual(table.selectedRow,2,"The selected game stays selected across the update")
        // The renamed collection's games kept their ids but now say "Uno": the cell was refreshed and opens the new row.
        let cell=try XCTUnwrap(table.view(atColumn:0,row:2,makeIfNecessary:false) as? GameRowCell)
        XCTAssertTrue(cell===shown,"The row kept its cell, so only the coordinator's reload can have refreshed it")
        XCTAssertEqual(cell.boundRow?.details,"Uno");XCTAssertEqual(cell.accessibilityIdentifier(),"library-row-collection:\(one):1")
        XCTAssertEqual(cell.boundRow,library.visibleRows.first{$0.id=="collection:\(one):1"})
        let added=try XCTUnwrap(table.view(atColumn:0,row:4,makeIfNecessary:true) as? GameRowCell);XCTAssertEqual(added.boundRow?.details,"Three")
        // Pressing the refreshed row opens the renamed game, not the one the cell first showed.
        var opened:[LibraryRow]=[];coordinator.openRow={opened.append($0)}
        XCTAssertTrue(cell.accessibilityPerformPress());XCTAssertEqual(opened.map(\.details),["Uno"])
    }
    /// Clearing a search that matched every line leaves the lines as they were, but the event headers it disabled
    /// must be enabled again.
    func testClearingASearchReenablesEventHeaders() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("library-table-\(UUID().uuidString)");defer{try? FileManager.default.removeItem(at:folder)}
        let library=ReviewLibraryController(directory:folder)
        library.publish(LibraryCatalog(library:try GameLibrary.load(),collections:[]));library.scope = .worldChampionships
        let coordinator=LibraryTable.Coordinator(library),table=LibraryTable.makeTable(coordinator);table.frame=NSRect(x:0,y:0,width:400,height:600)
        coordinator.apply(focusRequests:0);let unsearched=table.appliedIDs
        func headerEnabled()throws -> Bool {
            let cell=try XCTUnwrap(table.view(atColumn:0,row:0,makeIfNecessary:true) as? EventHeaderCell)
            return try XCTUnwrap(cell.subviews.compactMap{$0 as? HeaderButton}.first).isEnabled
        }
        XCTAssertTrue(try headerEnabled())
        library.query="world";coordinator.apply(focusRequests:0)
        XCTAssertEqual(table.appliedIDs,unsearched,"The search matches every championship game, so the lines are unchanged")
        XCTAssertFalse(try headerEnabled(),"Collapse is disabled while searching")
        library.query="";coordinator.apply(focusRequests:0)
        XCTAssertEqual(table.appliedVersion,library.shownVersion);XCTAssertTrue(try headerEnabled(),"Collapse is enabled again once the search is cleared")
    }
}
