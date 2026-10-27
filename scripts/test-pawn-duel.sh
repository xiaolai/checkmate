#!/bin/bash
# Silent test-host acceptance: every lesson mini-game takes a clicked move and the computer replies, and a game won by
# a clicked move opens its post-game review sheet (WI-018), whose Read Aloud, clicked with the silent voice double
# (`--voice-double`: no audio, no network), asks only for the proved fact's exact text and ends when the sheet closes.
exec bash "$(dirname "$0")/test-scenario.sh" --log pawn-duel-app.log --show passed --show games --show 'review?' --exited 'Mini-game scenario exited before writing results' --pawn-duel-scenario pawn-duel-results.json 120 --voice-double
