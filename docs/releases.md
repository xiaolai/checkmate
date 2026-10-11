# Checkmate releases

`Version.env` owns the native version and monotonically increasing build number.
Version 0.5.0 is build 13.
Version 0.5.0 targets macOS 14+ with universal Apple Silicon and Intel binaries.
Build tooling runs on build-host with Xcode 27; this is separate from the runtime target.
Development and release builds use
separate application identifiers and data directories.

Build and artifact verification run on build-host. The coordinating Mac signs the copied
artifacts and submits them through its existing `chase-notary` keychain profile.
Neither signing nor notarization executes application code; credentials are never copied. Following XiaolaiDict's release process, the app is signed with
hardened runtime and a secure timestamp, notarized and stapled before the DMG is
created. The DMG is signed, notarized and stapled separately. Verification mounts
the final image read-only and checks the shipped app's signature, ticket, resources
and Gatekeeper assessment. Hardened-runtime signing includes the audio-input
entitlement required by the voice coach, without debugger access. Building and signing launch no app and play
no audio; only final verification runs the shipped app, once (see below).

Synchronize the source to the build machine and run `bash scripts/acceptance.sh` there. It records the
source hashes before building and writes `acceptance.json` only when every gate passes on an unchanged tree.
Then run from this checkout, naming that evidence directory on the build machine:

```sh
CHECKMATE_RELEASE_HOST=build-host CHECKMATE_RELEASE_ROOT=/absolute/path/to/checkmate \
  CHECKMATE_ACCEPTANCE_EVIDENCE=/absolute/path/to/evidence bash scripts/release.sh
```

Run it from a clean checkout of tag `v<version>`: it refuses uncommitted changes, any
other commit, and an accepted tree whose source hashes differ from the tag's, and it
records the commit in the app's Info.plist (`CheckmateSourceCommit`). After it finishes,
`bash scripts/publish-release.sh` creates the GitHub release with the DMG, the tag's source
archive and `SHA256SUMS`, then dispatches `update-homebrew.yml`, which rewrites the
`xiaolai/tap` cask (it refuses to re-publish or downgrade and needs the `HOMEBREW_TAP_TOKEN`
secret).
Packaging refuses a tree whose source hashes differ from the accepted run. Final verification also runs the
mounted, notarized app once with `--package-check` (engine move, rules and lessons; no window, state or audio).

Before the remote build, `release.sh` checks the notary keychain profile (`notarytool history`) and that
the signing identity (`CHECKMATE_SIGN_ID`, default the Developer ID) is in this Mac's keychain, so neither
fails only after the build host has built the app.
`scripts/check-package.py` checks every package's version, build number, microphone usage string,
license files and the deployment target of each architecture slice; non-release builds must use their own
`ai.xiaolai.checkmate.*` identifier. `--release-identity` (the unsigned release build) also requires
`ai.xiaolai.checkmate` and the `CheckmateSourceCommit` stamp; `--release` (the mounted DMG) adds a
Developer ID signature, hardened runtime and secure timestamp on the app, CheckmateMCP and the engine.
Both hosts receive `build/release/Checkmate-<version>.dmg`; only the final
stapled DMG is distributable. Keep its SHA256 and matching source archive together.
The Stockfish source archive, build recipe, network and licenses are in this
repository. Signing changes Stockfish's bytes: the packaged build manifest retains
the original hash as `unsignedBinarySHA256` and records the signed hash, which
`check-package.py` compares with the shipped binary during packaging and final verification.
The app does not check the engine binary's hash at runtime: before first use it validates only the
network file, against a SHA-256 compiled into the app, and it uses the binary's hash only to identify
cached review analysis. The checkout's engine remains unmodified.

Release notes must distinguish automated verification from human acceptance.
Standard game review is available. Experimental quality labels, review voice and the beginner opponent remain opt-in until
human review, novice play and live audio/microphone checks have been completed.
Do not mark those criteria passed merely because the release has been packaged.

Git publication requires a configured remote. Never push unrelated tags or skip
hooks. Run Jev's `secret-scan` before commit/publication and `commit-message` on the
proposed message. Exclude raw agent sessions, build evidence, Python caches and
uncompressed recording masters from source history.

Compatibility acceptance distinguishes compilation and Rosetta execution on build-host
from physical Intel and macOS 14 runtime tests. Do not claim older-system runtime
acceptance solely from a lower deployment target or successful cross-compilation.
