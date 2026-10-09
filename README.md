# Checkmate

Native macOS 27 chess practice and learning, built with AppKit and SwiftUI.
Offline Stockfish 19, 40 lessons, 83 quizzes, 87 puzzles and 947 Cedar recordings.
Lesson mini-games include computer opponents. Game review is an opt-in pilot.

```sh
brew install --cask xiaolai/tap/checkmate
```

Requires Apple Silicon and macOS 27. [Native development](native/README.md),
[release packaging](native/RELEASE.md), [changelog](native/CHANGELOG.md).

To use Codex as a chess companion, choose **Set up Codex** in Settings →
Connections, then enable chess MCP connections and start a new Codex task with
`$checkmate-companion`.
The companion connects privately to Checkmate on this Mac.

Original code and owner-authored course materials: GPL-3.0-or-later. Third-party
licenses retain their own terms; see [notices](THIRD_PARTY_NOTICES.md). Matching
Stockfish source and its reproducible build recipe are included in
`native/ThirdParty/Stockfish/`. Lesson audio is AI-generated.
