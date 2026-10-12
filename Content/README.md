# Lesson scripts and Cedar recordings

The complete British-English rewrite is published in the native app with OpenAI Cedar narration at speed 1.0. All 40 lessons and 864 clips are bundled offline. Text, audio, transcript titles and timing are published together; stable lesson and recording IDs, authored illustrations and saved progress mappings are preserved. Embedded quiz questions have been removed; the subsequent explanations remain.

- `course-scripts.en-GB.json` is the editable source: all 40 lessons, 864 narration segments, lesson takeaways and 87 standalone puzzle explanations. The 83 embedded quiz segments are retired; retained segments keep their original recording IDs and lesson order.
- `lesson-scripts.en-GB.md` is the generated readable script book, including the retained narrated explanations.
- `lesson-narration.en-GB.jsonl` contains 864 recording units, one per existing segment. `text` is plain recording text; `displayText` is the transcript. Coordinates and written notation have pronunciation-friendly forms. `sha256` hashes the UTF-8 recording text. `outputStem` uses a new `voice-v2` path so recording work need not overwrite the existing clips.
- `puzzle-feedback.en-GB.jsonl` contains 87 **optional** feedback recording units, separate from the sequential lesson recordings. The current app does not yet play these as feedback audio.

The schema-2 editorial source has no audio files or generated timing metadata. Its `published` state records publication, but it is not directly loaded by the app. `course-baseline.json` and `projections-baseline.json` are immutable original snapshots used to check action and answer parity. The generated runtime is `Sources/CheckmateCore/Resources/course.json`, with compressed-asset provenance in `course-narration.json`.

The [2026-10-10 lesson audit](lesson-audit-20261010.md) covers every lesson and takeaway. `lesson-illustrations.json` records reviewed changes to original board actions; all other action fixtures and standalone puzzle answers remain pinned to the immutable baseline. The corrected knight illustrations show a jump from the complete starting position with friendly pawns unchanged.

Regenerate exports after editing the source:

```sh
python3 Tools/prepare-lesson-scripts.py
python3 Tools/prepare-lesson-scripts.py --check
```

The check verifies that all original embedded quizzes are retired, retained editorial board actions match their original segments or explicitly reviewed illustration corrections, and standalone puzzle mechanics, boards and IDs are unchanged. It also checks that exported recording inputs match the edited source. The pinned baseline hash is a provenance check: publishing changes the runtime without changing this baseline. Review parity before rebasing the original baseline.

For recording, send each JSONL unit's `text` to the chosen engine and retain its `id` and input hash with the output. This export is engine-neutral; the separate Cedar profile selects the recording engine and voice. Audition coordinates, the file letters, castling, en passant and Paul Morphy before generating the full set.

To publish new or changed recordings on build-host, run `python3 Tools/import-cedar-recordings.py`. It verifies the complete master set, converts to AAC using macOS Audio File Convert, fully decodes all final assets without playback, and measures durations using the same AVAudioPlayer implementation as the app. It publishes matching text, audio metadata, timing, transcript labels and lesson projections together. Each retained segment receives its original starting illustration, including setups previously supplied by a removed question. Assets use an immutable content-derived directory; reruns reuse verified compression. Original native resources are backed up under ignored `build/course-before-cedar/`, and obsolete takes are excluded from the bundle. The old reference import pipeline must not overwrite this native-owned editorial source.

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

`audition.html` groups sample takes by segment and speed, with explicit playback controls and no autoplay. Its audio is AI-generated. API success and WAV validation establish valid output, not correct pronunciation or pleasing delivery: listening review is still required. Xiaolai approved speed 1.0 on 2026-10-09 after comparing the audition set with 0.95. Full-course recording uses that pinned profile. Up to four requests may run concurrently, and the batch stops scheduling new requests after a failure while retaining completed takes.

The recorder also accepts `--api-key-stdin` for a key passed through an SSH pipe, avoiding storage on the recording host. The first audition run found that build-host's stored key was rejected; the successful runs used the main Mac's configured key supplied only to the remote process. That stored build-host credential has not been changed. WAV streaming-length headers are finalized without altering PCM samples; provenance retains both response and finalized-file hashes.

Offline recorder checks: `python3 Tools/test-record-lessons.py`. The complete rewritten course is now published through the coordinated importer described above. WAV masters should be preserved separately from compressed app assets, and any audio processing must be included in the final asset provenance.

Verify the complete speed-1.0 set with `python3 Tools/verify-lesson-recordings.py`. It fails if any expected segment is missing or has mismatched speech settings, text, provenance, audio hash or WAV duration. Only a complete valid set produces `completion-speed-1.json`, the ordered `lesson-recordings-speed-1.json` asset manifest, and `course-recordings.html` for manual review. The verifier reports whether the profile is published; it does not change app resources.

Packaging and timeline constants are centralized in `narration-packaging.json`. The runtime consumes the same timing values through `CourseTiming`; each transcript lasts long enough for narration, every authored move/removal, counting highlights, authored pauses and the end gap. A segment's arrows and highlights describe the position its moves produce, so they appear when its last move lands; until then only overlays carried over from the previous segment, and arrows previewing the segment's own moves, are shown. An attack arrow ends on the piece it attacks: it may cross a piece to show a pin, skewer or blocked line, but never runs past its target onto an empty square (`CourseTests` checks both). Importer contracts: `python3 Tools/test-import-cedar.py`. Native tests decode all 864 bundled clips without playing them.
