# Training decisions and deferrals

Decisions taken after the training mini-games work and its code audits, with the reason for each. They record what is deliberate, so a later audit does not reopen a settled question as a defect.

## Decisions

| Topic | Decision | Reason |
|---|---|---|
| Curated tiers | Curated exercise pools are chosen across all tiers. A scenario's tier is descriptive metadata. The preparation parameter is `generatedTier`, and it steers only generated drills. | No caller asks for a curated tier, and the plan defines no tier progression. A strict filter would make most authored content unreachable. Naming the parameter for what it does means no API suggests a filter that does not exist. |
| Checkmate and material | Exercise goals give checkmate precedence: gaining material while being mated fails, and delivering mate succeeds. Exchange classification (ahead, even, behind) reports the resolved material change. Mated and stalemated leaves are scored by material. | A goal asks whether the learner succeeded. An exchange question asks who came out ahead in material. These are two separate questions. |
| Retry scheduling | `addedAt`, read in the learner's Gregorian calendar and time zone, decides when a retry is due. The saved `notBefore` day is kept as a format-checked derived copy. | Keeping the field keeps the saved shape readable by earlier builds. Scheduling from `addedAt` stays correct across time zone and calendar changes. |
| Knight Corners progress | A solo route is stored in `legacyWins`, and "routes completed" is read from that counter alone. | Progress is keyed by game kind, so for Knight Corners that counter can only mean routes. A separate field would change the saved schema without changing behaviour. |
| Records from a newer version | The active attempt and each retry item are read on their own (WI-026). One this build cannot decode, or whose scenario carries a field it does not know, is kept raw in its place, written back unchanged, counted in the bounds, and never resumed or suggested; the rest of training stays writable. While such an attempt holds the active slot, an exercise started here is played and recorded but not saved for Continue. Events and credited runs of an unknown mini-game still keep the whole record raw. | Replacing or abandoning a newer attempt would lose it for the version that can finish it, and there is one active slot. Events hold no scenario, and no later build adds a mini-game kind, so an unknown kind there is damage. The rule is frozen in `Tests/Fixtures/TrainingCompatibility` for later builds' tests. |
| Voice stop button | Availability comes from a published `canStopTurn` on the voice coach. It covers generation, playback and outstanding cancellable turn work. | The visible status text is presentation and must not control behaviour. |
| Local audit records | `.cc-suite/` holds local audit tool output and is ignored by git. Decisions that matter are recorded here. | Tool output is regenerated per run, and this file is the reviewed record. |

## Release gates that remain human

Engineering work on Increment B is complete, but it is not a release. Increment B stays behind its preview flag until both of these are done:

- **Editorial review.** A person reviews the Increment B content. Every scenario's `reviewer` stays `null` until that happens, and an automated review is never recorded as one.
- **Beginner observation.** A real beginner is observed working through the tasks in `docs/training-observation.md`, with results recorded there.

The later legacy variations and advanced objectives depend on a verified Increment B release, so they wait on both steps.

Exception, decided by the product owner on 2026-10-18: the position games of
`dev-docs/codex-plans/20261018-mini-game-opponents-voice-lan.md` (WI-017, WI-019, WI-020) may be built before
Increment B is verified. Their content ships behind `CHECKMATE_POSITION_GAMES`, labelled machine-checked, and is
offered to learners only after the same editorial review and beginner observation. The other later items still
wait.

Calibration pass rule, decided by the product owner on 2026-10-20: a difficulty level is offered when it beats
the level below by at least 10 points against the greedy reference with disjoint 95% Wilson intervals, or, once
greedy is saturated for the level below, when it scores at least 60% against that level head-to-head with a
Wilson lower bound above 50% (`MiniGameCalibration.pair`; the manifest pins both numbers). Greedy cannot measure a difference it has no room left to show.

## Deliberate deferrals

| Change | Why it waits | What it needs before it starts |
|---|---|---|
| Split `GameSession` (presentation lifecycle, protocol projection) | The split is structural only. It reaches the companion protocol and every presentation path. Frame-change cleanup is already centralised in `presentationFrameChanged()`. | Companion protocol contract tests, the integration gate, and pointer coverage for previews and demonstrations. |
| Split `GameWindow` (drawer geometry, board presentation) | It touches the square board, outward drawers, centred title, fullscreen and resizing invariants. | The pointer, layout, fullscreen and UI gates, run before and after on the build machine. |
