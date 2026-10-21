#!/usr/bin/env swift
import Foundation
// Explicit long, silent gate. Never silently substitute positions for games.
// The test host carries ~/.config/checkmate/host-role naming "test" (alone or with "build"), the marker scripts/test_host.py reads.
let hostRoles=Set(((try? String(contentsOf:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/checkmate/host-role"),encoding:.utf8)) ?? "").split(whereSeparator:\.isWhitespace).map(String.init))
guard hostRoles.contains("test") else{fatalError("Run native calibration on the test host only.")}
let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/env");let scratch=ProcessInfo.processInfo.environment["CHECKMATE_BUILD_PATH"] ?? ".build-review";process.arguments=["python3","scripts/fresh-sources.py",scratch,"--","swift","test","--scratch-path",scratch,"--filter","OpponentCalibration"]
var environment=ProcessInfo.processInfo.environment;environment["CHECKMATE_AUTOMATION"]="1";environment["CHECKMATE_CALIBRATION_GAMES"]=environment["CHECKMATE_CALIBRATION_GAMES"] ?? "100";environment["CHECKMATE_CALIBRATION_NODES"]=environment["CHECKMATE_CALIBRATION_NODES"] ?? "1000";environment["CHECKMATE_CALIBRATION_DIR"]=environment["CHECKMATE_CALIBRATION_DIR"] ?? FileManager.default.currentDirectoryPath+"/evidence/game-review-20261009";process.environment=environment
try FileManager.default.createDirectory(atPath:environment["CHECKMATE_CALIBRATION_DIR"]!,withIntermediateDirectories:true);try process.run();process.waitUntilExit();exit(process.terminationStatus)
