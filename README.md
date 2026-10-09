# Checkmate

Native macOS 27 chess practice and learning, built with AppKit and SwiftUI.
Offline Stockfish 19, 40 lessons, 83 quizzes, 87 puzzles and 947 Cedar recordings.
Lesson mini-games include computer opponents. Game review is an opt-in pilot.

```sh
brew install --cask xiaolai/tap/checkmate
```

Requires Apple Silicon and macOS 27. [Native development](native/README.md),
[release packaging](native/RELEASE.md), [changelog](native/CHANGELOG.md).

The application needs no Node or web runtime. The optional external MCP adapter
uses Node 22+ and pnpm; build it with `pnpm companion:build`, then run
`node packages/companion-mcp/dist/packages/companion-mcp/src/cli.js`. Its chess-specific tools connect to
the running native app's private local broker. The companion skill is under
`companion/skills/checkmate-companion/`.

Original code and owner-authored course materials: GPL-3.0-or-later. Third-party
licenses retain their own terms; see [notices](THIRD_PARTY_NOTICES.md). Matching
Stockfish source and its reproducible build recipe are included in
`native/ThirdParty/Stockfish/`. Lesson audio is AI-generated.
