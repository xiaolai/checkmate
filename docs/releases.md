# Checkmate releases

`Version.env` owns the native version and monotonically increasing build number.
Version 0.3.6 is build 11.
Version 0.3.6 targets macOS 14+ with universal Apple Silicon and Intel binaries.
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
entitlement required by the voice coach, without debugger access. No app is launched or audio played by packaging.

Synchronize the source to the build machine, run the silent native test suite,
then run from this checkout:

```sh
CHECKMATE_RELEASE_HOST=build-host CHECKMATE_RELEASE_ROOT=/absolute/path/to/checkmate bash scripts/release.sh
```

The script refuses to continue without working signing/notarization prerequisites.
Both hosts receive `build/release/Checkmate-<version>.dmg`; only the final
stapled DMG is distributable. Keep its SHA256 and matching source archive together.
The Stockfish source archive, build recipe, network and licenses are in this
repository. Signing changes Stockfish's bytes: the packaged build manifest retains
the original hash as `unsignedBinarySHA256` and records the signed hash used by
runtime integrity checks. The checkout's engine remains unmodified.

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
