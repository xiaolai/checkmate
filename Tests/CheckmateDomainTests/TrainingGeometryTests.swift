import XCTest
import CheckmateDomain
/// Hand-checked geometry: each expected set below was worked out on a board, not produced by the code under test.
final class TrainingGeometryTests:XCTestCase {
    func testRaysStopAtTheFirstPieceButReachIt(){
        let board:Position=["d4":"wr","d6":"bp","d2":"wp","f4":"bn","b4":"wq"]
        XCTAssertEqual(TrainingGeometry.attacks(from:"d4",board:board),["d5","d6","d3","d2","e4","f4","c4","b4"],"stops at d6, d2, f4 and b4, attacking or defending each")
        XCTAssertEqual(TrainingGeometry.attacks(from:"a1",board:["a1":"wb","c3":"wp"]),["b2","c3"])
    }
    func testPawnsAttackDiagonallyForwardOnlyByColour(){
        XCTAssertEqual(TrainingGeometry.attacks(from:"e4",board:["e4":"wp"]),["d5","f5"])
        XCTAssertEqual(TrainingGeometry.attacks(from:"e4",board:["e4":"bp"]),["d3","f3"])
        XCTAssertEqual(TrainingGeometry.attacks(from:"a7",board:["a7":"bp"]),["b6"],"edge file")
        XCTAssertEqual(TrainingGeometry.attacks(from:"e4",board:["e4":"wp","e5":"bp"]),["d5","f5"],"a blocked push does not change pawn attacks")
    }
    func testKnightsAndKings(){
        XCTAssertEqual(TrainingGeometry.attacks(from:"a1",board:["a1":"wn","b2":"wp","b1":"bp"]),["b3","c2"],"knights jump over pieces")
        XCTAssertEqual(TrainingGeometry.attacks(from:"h8",board:["h8":"bk"]),["g8","g7","h7"])
    }
    func testAttackersIncludePinnedPiecesAndExcludeBlockedLines(){
        // The white knight on d2 is pinned to its king on e1 by the bishop on a5, yet still attacks e4.
        let pinned:Position=["e1":"wk","d2":"wn","a5":"bb","e4":"bp","e8":"bk"]
        XCTAssertEqual(TrainingGeometry.attackers(of:"e4",color:"w",board:pinned),["d2"])
        // The rook on a4 is blocked by the pawn on c4; the queen on e8 attacks e4 down the open file; the king on e1 does not reach.
        let lines:Position=["a4":"wr","c4":"bp","e8":"wq","e1":"wk","e4":"bn","g3":"wp","f3":"wp"]
        XCTAssertEqual(TrainingGeometry.attackers(of:"e4",color:"w",board:lines),["e8","f3"],"f3 attacks e4 and g4; g3 attacks f4 and h4")
        XCTAssertEqual(TrainingGeometry.attackers(of:"e4",color:"b",board:lines),[],"an intentionally empty set")
    }
    func testKingsAttackAndFriendlyOccupiedSquaresAreDefended(){
        let board:Position=["e4":"wn","e3":"wk","d3":"wp","c2":"wb","h4":"wr","g4":"bp"]
        // d3 attacks c4 and e4; the king on e3 is adjacent; the bishop c2 is blocked by d3; the rook h4 is blocked by g4.
        XCTAssertEqual(TrainingGeometry.defenders(of:"e4",board:board),["d3","e3"])
        XCTAssertEqual(TrainingGeometry.defenders(of:"a1",board:board),[],"an empty square has no defenders")
        XCTAssertEqual(TrainingGeometry.defenders(of:"g4",board:board),[],"g4 holds the only black piece")
    }
}
/// Movement drills: exact BFS distances, alternative routes and the fixed-piece rules.
final class TrainingPathTests:XCTestCase {
    func testKnightDistancesAndAlternativeRoutes()throws {
        let drill=MovementDrill(piece:"wn",start:"a1",target:"b2",pieces:[:])
        XCTAssertEqual(drill.distance(from:drill.initial),4,"a knight needs four moves from a corner to its diagonal neighbour")
        let open=MovementDrill(piece:"wn",start:"b1",target:"d4",pieces:[:])
        XCTAssertEqual(open.distance(from:open.initial),3)
        // Two different shortest routes both stay on budget.
        for route in [["c3","b5"],["d2","f3"]] {
            var state=open.initial;for square in route{state=try XCTUnwrap(open.apply(state,to:square))}
            XCTAssertEqual(open.distance(from:state),1,route.joined(separator:" "))
        }
    }
    func testBishopColourAndBlockers(){
        let wrongColour=MovementDrill(piece:"bb",start:"c8",target:"c7",pieces:[:])
        XCTAssertNil(wrongColour.distance(from:wrongColour.initial),"a bishop never changes square colour")
        let blocked=MovementDrill(piece:"wr",start:"a1",target:"a8",pieces:["a4":"wp"])
        XCTAssertEqual(blocked.distance(from:blocked.initial),3,"around its own pawn: a1-b1-b8-a8 or similar")
        let capture=MovementDrill(piece:"wr",start:"a1",target:"a8",pieces:["a4":"bp"])
        XCTAssertEqual(capture.distance(from:capture.initial),2,"capturing the enemy pawn opens the file")
        XCTAssertFalse(capture.moves(capture.initial).contains{$0.to=="a5"},"no passing through a piece")
    }
    func testKingNeverStepsOntoAttackedSquares(){
        let drill=MovementDrill(piece:"wk",start:"e1",target:"e3",pieces:["d8":"br"])
        XCTAssertFalse(drill.moves(drill.initial).contains{$0.to.hasPrefix("d")},"the d-file is attacked")
        XCTAssertEqual(drill.distance(from:drill.initial),2)
        // A protected enemy piece cannot be captured by the king; an unprotected one can.
        let guarded=MovementDrill(piece:"wk",start:"e1",target:"e3",pieces:["e2":"bn","e8":"br"])
        XCTAssertFalse(guarded.moves(guarded.initial).contains{$0.to=="e2"})
        let free=MovementDrill(piece:"wk",start:"e1",target:"e3",pieces:["e2":"bn"])
        XCTAssertTrue(free.moves(free.initial).contains{$0.to=="e2" && $0.captures=="e2"})
        // The king may not retreat along the line of a slider attacking it from behind.
        let line=MovementDrill(piece:"bk",start:"d5",target:"f7",pieces:["a5":"wr"])
        XCTAssertFalse(line.moves(line.initial).contains{$0.to=="e5"})
    }
    func testPawnsPushCaptureAndStop(){
        let push=MovementDrill(piece:"wp",start:"e2",target:"e5",pieces:[:])
        XCTAssertEqual(push.distance(from:push.initial),2,"double step, then one")
        let blocked=MovementDrill(piece:"bp",start:"d7",target:"d4",pieces:["d6":"wn"])
        XCTAssertNil(blocked.distance(from:blocked.initial),"a pawn cannot capture straight ahead")
        let around=MovementDrill(piece:"bp",start:"d7",target:"c4",pieces:["d6":"wn","c6":"wp"])
        XCTAssertEqual(around.distance(from:around.initial),3,"captures c6, then pushes twice")
        let promoted=MovementDrill(piece:"wp",start:"a7",target:"b8",pieces:[:])
        XCTAssertNil(promoted.distance(from:promoted.initial),"no diagonal move without a capture")
    }
    func testGeneratorsAreDeterministicAndValid(){
        for tier in 1...3 {for color:Character in ["w","b"] {
            XCTAssertEqual(TrainingGenerator.reachTarget(seed:42,tier:tier,color:color,piece:"n"),TrainingGenerator.reachTarget(seed:42,tier:tier,color:color,piece:"n"))
            XCTAssertEqual(TrainingGenerator.findAttackers(seed:7,tier:tier,color:color),TrainingGenerator.findAttackers(seed:7,tier:tier,color:color))
        }}
        XCTAssertNotEqual(TrainingGenerator.findAttackers(seed:7,tier:2,color:"w"),TrainingGenerator.findAttackers(seed:8,tier:2,color:"w"))
    }
    func testRandomIsStableAcrossPlatforms(){
        var random=TrainingRandom(seed:0)
        XCTAssertEqual(random.next(),0xe220a8397b1dcdaf,"SplitMix64 reference value");XCTAssertEqual(random.next(),0x6e789e6aa1b965f4)
    }
    func testAnEnemyKingBlocksButIsNeverCaptured(){
        let drill=MovementDrill(piece:"wk",start:"e1",target:"e3",pieces:["e2":"bk"])
        XCTAssertFalse(drill.moves(drill.initial).map(\.to).contains("e2"),"a king is never a capture target")
        let rook=MovementDrill(piece:"wr",start:"a1",target:"a8",pieces:["a4":"bk"])
        XCTAssertEqual(Set(rook.moves(rook.initial).map(\.to)).intersection(["a4","a5"]),[],"the enemy king blocks the file and cannot be taken")
    }
}
