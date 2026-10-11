# Module ownership

Checkmate uses SwiftPM targets to enforce dependency direction. Native windows remain AppKit/SwiftUI; shared application behavior lives below the native host. `Package.swift` is the authoritative dependency graph, and `scripts/test-module-boundaries.py` checks both that graph and source imports. Its negative fixtures verify that forbidden imports, reverse dependencies and implementation in the compatibility facade fail the gate.

| Target | Owns | Platform considerations |
| --- | --- | --- |
| CheckmateAssets | Bundled chess.js, Stockfish, lessons, recordings, schemas and licenses; resource lookup | Source assets remain in `Sources/CheckmateCore/Resources`; the bundle is `Checkmate_CheckmateAssets.bundle` |
| CheckmateDomain | Saved-state models, chess/engine values, activity, course content, mini-game rules, opponent policies, engine and narration contracts | Foundation/CoreFoundation only, plus asset lookup; no UI, process, observation or service SDK |
| CheckmateSupport | Error projection, schema validation, JSON projections, hashes, logs, data-directory policy | CryptoKit and OSLog require platform replacements for Windows |
| CheckmateRules | Chess rules facade and isolated script-runtime contract | Current default adapter uses JavaScriptCore; injected factories survive copy and restore |
| CheckmateEngine | Stockfish process lifecycle, UCI protocol, canonical move validation, NNUE identity and search cancellation | Current implementation uses Foundation Process, Darwin and Combine |
| CheckmateContent | Localization/recording packs, language jobs, Codex and voice gateways, usage accounting, companion installation | No application-controller or native-UI dependency; subscription/CLI/filesystem behavior still requires platform validation |
| CheckmateApplication | Practice, learning, reviews, beginner opponent selection, persistence, migration, tool routing and workspace entry | Depends on the engine protocol in Domain; no dependency on the Stockfish implementation or macOS service module. Current controllers use Combine |
| CheckmateMacPlatform | Narration, voice audio/transport, companion HTTP broker and window geometry | AVFoundation, CoreAudio, Network, Security and CoreGraphics |
| CheckmateCore | Compatibility exports only | Imports all modules for existing consumers; new shared code must import its owner instead |
| CheckmateNative | Windows, toolbar, drawers, settings, board rendering, user prompts and native composition | AppKit/SwiftUI; the released and automation identities remain separate |
| CheckmateMCPKit / CheckmateMCP | MCP SDK adapter, discovery and stdio transport | Existing MCP schemas and errors are unchanged |

`CheckmateDomain` and `CheckmateApplication` are library products. Targets cannot import upstream consumers or native UI. The application does not cast an engine to `NativeEngine`; `EngineService` requires history-aware searches, search-move constraints, strength profiles and metadata. Cancellation remains Swift task cancellation, implemented by the Stockfish worker's generation-scoped cancellation handler. Position-only fake engines belong exclusively to `CheckmateTestSupport`.

`ChessRules` accepts a factory for an isolated `ChessScriptRuntime`. Its default is the current JavaScriptCore adapter. Copies and staged PGN restoration reuse that factory, preserving independent game state and the existing chess.js behavior. A replacement runtime must implement the same script/JSON contract.

## Workspace lifecycle

`WorkspaceTransitionCoordinator` prepares review restoration, imported progress and practice positions before the host leaves its current activity. It also owns entry into practice, lessons, puzzles and reviews. `NativeModel` keeps modal consent, generation checks, unsaved review snapshots, backup writes, native service teardown and save notifications. Existing order remains: consent and stale-request checks, fallible preparation and backup, exit, then entry. A failed preparation does not change the activity or board.

This extraction intentionally keeps native lifecycle effects with the host. Any new frontend must implement those host responsibilities, including save failures, stale modal requests, pending imports and explicit resume after a failed restore.

## Adding features

1. Put values, saved-state fields and pure policy in Domain. Preserve Codable keys and unknown-field round trips.
2. Put workflows in Application, using Domain contracts. Add native or external services below the appropriate adapter boundary; never import native UI into a workflow.
3. Implement user interaction and composition in the native host. Keep real games and hypothetical boards separate.
4. Add regression tests to the owning test suite. Domain tests import only Domain; native interaction tests live in `CheckmateNativeTests`; integration and controller tests live in `CheckmateCoreTests`.
5. Update `scripts/gates.json` when a file moves or a new responsibility is added. Run the architecture gate, map and gate-selection checks on build-host, then only the acceptance gates the change touches.

## A future native Windows app

These boundaries make reusable behavior identifiable and prevent new UI dependencies from spreading into it. They do not establish a working Windows build. The current manifest and released products target macOS.

A Windows implementation still needs a native frontend, an alternative chess.js runtime, a Windows Stockfish process adapter, audio/device/network/credential adapters, platform logging/hashing and a replacement or bridge for Combine observation. It must also validate Foundation/CoreFoundation support, CLI discovery, data paths, resource packaging and engine cancellation on Windows. Keep existing saved-state and MCP formats at those boundaries.

Choose the Windows frontend and interoperability strategy before implementing it. A Swift Windows host can consume the library products where supported. A WinUI/C# or C++ host needs an explicit bridge or service protocol; Swift target boundaries alone do not provide that ABI. Avoid duplicating chess and learning behavior in the new UI. A later portability phase should replace the remaining runtime dependencies behind these boundaries, with tests on a Windows host.
