# Training decisions and deferrals

Decisions taken after the training mini-games work and its code audits, with the reason for each. They record what is deliberate, so a later audit does not reopen a settled question as a defect.

## Decisions

| Topic | Decision | Reason |
|---|---|---|
| Curated tiers | Curated exercise pools are chosen across all tiers. A scenario's tier is descriptive metadata. The preparation parameter is `generatedTier`, and it steers only generated drills. | No caller asks for a curated tier, and the plan defines no tier progression. A strict filter would make most authored content unreachable. Naming the parameter for what it does means no API suggests a filter that does not exist. |
| Checkmate and material | Exercise goals give checkmate precedence: gaining material while being mated fails, and delivering mate succeeds. Exchange classification (ahead, even, behind) reports the resolved material change. Mated and stalemated leaves are scored by material. | A goal asks whether the learner succeeded. An exchange question asks who came out ahead in material. These are two separate questions. |
| Retry scheduling | `addedAt`, read in the learner's Gregorian calendar and time zone, decides when a retry is due. The saved `notBefore` day is kept as a format-checked derived copy. | Keeping the field keeps the saved shape readable by earlier builds. Scheduling from `addedAt` stays correct across time zone and calendar changes. |
| Knight Corners progress | A solo route is stored in `legacyWins`, and "routes completed" is read from that counter alone. | Progress is keyed by game kind, so for Knight Corners that counter can only mean routes. A separate field would change the saved schema without changing behaviour. |
| Voice stop button | Availability comes from a published `canStopTurn` on the voice coach. It covers generation, playback and outstanding cancellable turn work. | The visible status text is presentation and must not control behaviour. |
| Local audit records | `.cc-suite/` holds local audit tool output and is ignored by git. Decisions that matter are recorded here. | Tool output is regenerated per run, and this file is the reviewed record. |

## Release gates that remain human

Engineering work on Increment B is complete, but it is not a release. Increment B stays behind its preview flag until both of these are done:

- **Editorial review.** A person reviews the Increment B content. Every scenario's `reviewer` stays `null` until that happens, and an automated review is never recorded as one.
- **Beginner observation.** A real beginner is observed working through the tasks in `docs/training-observation.md`, with results recorded there.

The later legacy variations and advanced objectives depend on a verified Increment B release, so they wait on both steps.

## Deliberate deferrals

| Change | Why it waits | What it needs before it starts |
|---|---|---|
| Split `GameSession` (presentation lifecycle, protocol projection) | The split is structural only. It reaches the companion protocol and every presentation path. Frame-change cleanup is already centralised in `presentationFrameChanged()`. | Companion protocol contract tests, the integration gate, and pointer coverage for previews and demonstrations. |
| Split `GameWindow` (drawer geometry, board presentation) | It touches the square board, outward drawers, centred title, fullscreen and resizing invariants. | The pointer, layout, fullscreen and UI gates, run before and after on the build machine. |
