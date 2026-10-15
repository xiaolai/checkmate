#!/usr/bin/env swift
import Foundation
// Explicit long, silent gate. Never silently substitute positions for games.
let host=ProcessInfo.processInfo.hostName.lowercased()
guard host.contains("test-host") else{fatalError("Run native calibration on test-host only.")}
let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/env");process.arguments=["swift","test","--scratch-path",ProcessInfo.processInfo.environment["CHECKMATE_BUILD_PATH"] ?? ".build-review","--filter","OpponentCalibration"]
var environment=ProcessInfo.processInfo.environment;environment["CHECKMATE_AUTOMATION"]="1";environment["CHECKMATE_CALIBRATION_GAMES"]=environment["CHECKMATE_CALIBRATION_GAMES"] ?? "100";environment["CHECKMATE_CALIBRATION_NODES"]=environment["CHECKMATE_CALIBRATION_NODES"] ?? "1000";environment["CHECKMATE_CALIBRATION_DIR"]=environment["CHECKMATE_CALIBRATION_DIR"] ?? FileManager.default.currentDirectoryPath+"/evidence/game-review-20261009";process.environment=environment
try FileManager.default.createDirectory(atPath:environment["CHECKMATE_CALIBRATION_DIR"]!,withIntermediateDirectories:true);try process.run();process.waitUntilExit();exit(process.terminationStatus)
