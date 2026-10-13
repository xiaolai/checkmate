# Lesson scripts and Cedar recordings

The British-English beginner course is published in the native app with OpenAI Cedar narration at speed 1.0. All 39 lessons and 710 clips are bundled offline. Text, audio, transcript titles and timing are published together.

- `course-scripts.en-GB.json` is the editable source (schema 3): 39 lessons with their takeaways, 710 narration beats and 82 standalone puzzles. Beat ids are `<lesson>:<index>`, consecutive from 0. Each beat carries its narration (`say`, and `speak` when the recording needs a different text), its step label and title card, and its board actions: `set`, `moves`, `remove`, `hl`, `arrows`, `count`, `pause`. A beat without `set` continues from the previous beat's final board. A lesson's optional `practice` is the exercise played on its invitation beat (`beat`, whose board is the practice FEN): checkpoints that say what counts as doing it (in any order), the computer opponent, two hints, feedback texts and an optional teaching graph (`teaching`) of accepted moves with the computer's authored replies.
- A lesson with `practiceFor` is a practice activity for the named lesson, which must be the nearest main lesson before it. The app lists it indented under that lesson and keeps it off the main path (Continue skips it; the lesson offers Practise).
- `lesson-scripts.en-GB.md` is the generated readable script book.
- `lesson-narration.en-GB.jsonl` contains 710 recording units, one per beat. `text` is plain recording text; `displayText` is the transcript. Coordinates and written notation have pronunciation-friendly forms. `sha256` hashes the UTF-8 recording text.
- `puzzle-feedback.en-GB.jsonl` contains 82 **optional** feedback recording units, separate from the sequential lesson recordings. The current app does not yet play these as feedback audio.
- `course-sounds.json` holds the move sounds published with the course.
- `lesson-action-phrases.json` names, for each beat with two or more moves, the sentence that announces each move; `Tools/align-lesson-actions.py` turns them into `lesson-action-cues.json` timings from the recordings.

## Checks

`Tools/prepare-lesson-scripts.py --check` (run by the unit gate) validates the source with the rules in `Tools/lesson_rules.py`:

- every authored move is legal for its piece on the board shown: paths are clear, pawns capture diagonally, castling is the king's two-square move followed by its rook and is refused out of, through or into check, en passant removes the passed pawn, a pawn reaching the last rank names its new piece, and no move leaves its own king attacked;
- every check mark is on an attacked king, and every arrow follows a piece's line on the board it describes;
- every move and square puzzle states a claim (mate, stalemate, check, safe capture, castling, promotion, fork, escape from check, attackers, undefended pieces, a king's route, …), and its answer set is exactly the moves or squares that satisfy the claim;
- every practice exercise has exact fields, a beat showing its FEN, known checkpoint kinds with short labels, two hints and bounded texts, and its teaching graph replays legally (castling rights, en passant, promotion) with matching fingerprints, a reply exactly where the graph continues, and no unreachable node or loop; every checkpoint is possible from the start, and `mistakes`, `offTrack` and the hints describe the starting position, the only place the app shows them;
- narration never names an app control (button, panel, sidebar, toolbar or tab), since audio is not re-recorded when the interface changes, and a lesson named in narration exists under that title;
- nothing of an earlier course this app once adapted returns: `provenance-blocklist.json` holds only truncated SHA-256 digests of that course's eight-word phrases, names and board positions, and `Tools/provenance.py` compares normalised text and boards against them. Only the full starting position may match. A short reviewed allowance covers stock sequences (the file letters, the rank numbers spelled out).

`uv run --with chess Tools/audit-lesson-rules.py` repeats the move, check-mark and puzzle-answer checks on the published course with python-chess, an independent rules implementation, and checks the chess behind every practice exercise: every checkpoint is possible from the start, castling and en-passant graphs accept exactly the legal moves of their kind, Scholar's Mate accepts exactly the developing moves that stop the mate, and each tactic graph's moves have the tactic's geometry, win its stated gain against every defence in a fixed-depth material search, use a best defence as the authored reply, and leave out no winning move of that shape. `--mutations` plants defects in memory and requires the audit to reject each. `Tools/render-lesson.py <lesson>` prints any lesson as text boards, beat by beat, for review.

Regenerate exports after editing the source:

```sh
python3 Tools/prepare-lesson-scripts.py
python3 Tools/prepare-lesson-scripts.py --check
```

The check also verifies that the exported recording inputs match the edited source.

For recording, send each JSONL unit's `text` to the chosen engine and retain its `id` and input hash with the output. This export is engine-neutral; the separate Cedar profile selects the recording engine and voice. Audition coordinates, the file letters, castling, en passant and the players' names in the famous game before generating the full set.

To publish new or changed recordings on build-host, run `python3 Tools/import-cedar-recordings.py`. It verifies the complete master set, converts to AAC using macOS Audio File Convert, fully decodes all final assets without playback, and measures durations using the same AVAudioPlayer implementation as the app. It publishes matching text, audio metadata, timing, transcript labels and lesson projections together. Assets use an immutable content-derived directory; reruns reuse verified compression. Obsolete takes are excluded from the bundle.

## Cedar recordings

`narration-profile.cedar.json` pins OpenAI Cedar, the `gpt-4o-mini-tts-2025-12-15` snapshot, British-English delivery instructions, WAV masters and speed 1.0. This recording profile is independent of a learner's live-coach voice preference. The coach defaults to Cedar for new or missing/invalid settings; existing valid preferences are retained.

Run recording work on build-host. The recorder uses `OPENAI_API_KEY` from the environment or the matching assignment in `~/.aienv`. It does not use Codex voice-session credentials, print keys, play audio or change runtime content.

```sh
python3 Tools/record-lessons.py --sample                     # dry run, no API call
python3 Tools/record-lessons.py --sample --generate          # eight paid audition clips
python3 Tools/record-lessons.py --sample --speed 0.95 --generate
python3 Tools/record-lessons.py --lesson intro --generate    # explicit lesson selection
python3 Tools/record-lessons.py --all --jobs 4 --generate    # full set, after audition review
```

Generated audio, provenance sidecars and indexes live in ignored `recordings/cedar/`. Each request hashes all speech parameters, including the spoken text and delivery instructions. Finished, integrity-checked takes are reused; a changed parameter gets a different filename. Keep the recordings, because regeneration is not an exact reproduction. HTTP rate limits/transient server errors receive bounded retries; ambiguous network failures stop without blind retries. Incomplete or corrupt recording pairs require inspection before regeneration.

`audition.html` groups sample takes by segment and speed, with explicit playback controls and no autoplay. Its audio is AI-generated. API success and WAV validation establish valid output, not correct pronunciation or pleasing delivery: listening review is still required. Speed 1.0 was approved on 2026-10-09 after comparing the audition set with 0.95. Full-course recording uses that pinned profile. Up to four requests may run concurrently, and the batch stops scheduling new requests after a failure while retaining completed takes.

The recorder also accepts `--api-key-stdin` for a key passed through an SSH pipe, avoiding storage on the recording host. The first audition run found that build-host's stored key was rejected; the successful runs used the main Mac's configured key supplied only to the remote process. That stored build-host credential has not been changed. WAV streaming-length headers are finalized without altering PCM samples; provenance retains both response and finalized-file hashes.

Offline recorder checks: `python3 Tools/test-record-lessons.py`. WAV masters should be preserved separately from compressed app assets, and any audio processing must be included in the final asset provenance.

Verify the complete speed-1.0 set with `python3 Tools/verify-lesson-recordings.py`. It fails if any expected segment is missing or has mismatched speech settings, text, provenance, audio hash or WAV duration. Only a complete valid set produces `completion-speed-1.json`, the ordered `lesson-recordings-speed-1.json` asset manifest, and `course-recordings.html` for manual review. The verifier reports whether the profile is published; it does not change app resources.

Packaging and timeline constants are centralized in `narration-packaging.json`. The runtime consumes the same timing values through `CourseTiming`; each transcript lasts long enough for narration, every authored move/removal, counting highlights, authored pauses and the end gap. A segment's arrows and highlights describe the position its moves produce, so they appear when its last move lands; until then only overlays carried over from the previous segment, and arrows previewing the segment's own moves, are shown. An attack arrow ends on the piece it attacks: it may cross a piece to show a pin, skewer or blocked line, but never runs past its target onto an empty square (`CourseTests` checks both). Importer contracts: `python3 Tools/test-import-cedar.py`. Native tests decode all 710 bundled clips without playing them.
