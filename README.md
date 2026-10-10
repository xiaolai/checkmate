# Checkmate

Native macOS chess practice and learning, built with AppKit and SwiftUI.
Offline Stockfish 19, 40 lessons, 83 quizzes, 87 puzzles and 947 Cedar recordings.
Lesson mini-games include computer opponents. Game review is an opt-in pilot.

```sh
brew install --cask xiaolai/tap/checkmate
```

Requires macOS 14 or later. One universal app supports Apple Silicon and Intel Macs. [Development](docs/development.md),
[release packaging](docs/releases.md), [changelog](CHANGELOG.md).

To use Codex as a chess companion, choose **Set up Codex** in Settings →
Connections, then enable chess MCP connections and start a new Codex task with
`$checkmate-companion`.
The companion connects privately to Checkmate on this Mac.

Original code and owner-authored course materials: GPL-3.0-or-later. Third-party
licenses retain their own terms; see [notices](THIRD_PARTY_NOTICES.md). Matching
Stockfish source and its reproducible build recipe are included in
`ThirdParty/Stockfish/`. Lesson audio is AI-generated.

## Repository layout

The Swift package lives at the repository root. Run development commands from this directory.

- `Sources/` and `Tests/`: application, native MCP companion, and tests.
- `Artwork/`, `Content/`, and `ThirdParty/`: design assets, lesson scripts, and upstream source.
- `Tools/` and `scripts/`: content tooling, build verification, and release automation.
- `docs/`: development and release documentation.
- `companion/`: the Codex coaching skill.

Local builds, recordings, evidence, and private development notes are ignored by Git.
