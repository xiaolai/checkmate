# Checkmate

Native macOS chess practice and learning, built with AppKit and SwiftUI.
Offline Stockfish 19, 40 lessons, 87 puzzles and 864 Cedar recordings.
Lesson mini-games include computer opponents. Game review supports finished and unfinished games, PGN files and FEN positions.

```sh
brew install --cask xiaolai/tap/checkmate
```

Requires macOS 14 or later. One universal app supports Apple Silicon and Intel Macs. [Development](docs/development.md),
[release packaging](docs/releases.md), [changelog](CHANGELOG.md).

At launch, Checkmate checks Codex availability and can connect the voice coach
and start its private chess MCP broker automatically. Control these separately
in Settings → Voice Coach and Settings → Connections. Existing voice opt-outs
are preserved. While voice is connected, external MCP waits for control.
The coach automatically selects the newest compatible model from its supported stable list (currently GPT-Realtime-2.1 and GPT-Realtime-2). A silent check verifies reasoning effort and chess tools; the result is cached for this app session for up to 24 hours. Settings → Voice Coach → Check availability refreshes the selection. The selected model is shown in Settings and remains fixed throughout a conversation. Choose reasoning effort in Settings → Voice Coach;
Minimal is the default, with Low, Medium, High and Extra high available.
Changes apply to subsequent responses without reconnecting.

For an external Codex companion, choose **Set up Codex** once in Settings →
Connections, then start a new Codex task with `$checkmate-companion`.

In Settings → Lessons, choose a language and translate one lesson or the whole
course with your signed-in Codex account. Inspect the translated text, generate
and play a preview, then choose **Record / Resume**. Cedar is the default voice;
Marin is also available. Completed recordings play offline. A lesson uses English
until its selected language and voice have a complete recording set. You can
discard a translation to replace it without losing lesson progress.

Settings → Usage shows Checkmate's translation, recording, coaching and input
transcription activity. Provider credit and USD estimates appear when available;
they are not actual charges. Missing counters and voice subscription attribution
remain unknown. Account status is refreshed separately, and usage history can be
exported or cleared.

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
