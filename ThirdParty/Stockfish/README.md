# Stockfish 19 reproducible packaging

The source archive is the unmodified official `sf_19` tag. Check `Resources/stockfish-build.json` for its SHA256 and the binary/network hashes. Compile only on build-host:

```sh
bash Tools/build-stockfish.sh
```

The script compiles Apple Silicon and baseline Intel x86-64 slices from the same pinned source, combines them with `lipo`, ad-hoc signs the binary, and updates its hash and architecture manifest. The baseline Intel build uses SSE2 rather than assuming AVX2 or AVX-512.

Keep the resulting `stockfish` and the official `nn-1a298aa575a0.nnue` from `https://tests.stockfishchess.org/api/nn/nn-1a298aa575a0.nnue` beside each other in CheckmateCore's Resources. The network's complete expected SHA256 is in the manifest and validated before use. No evaluation, search, or neural-network changes are made. External packaging removes the permanently resident compressed embedded copy. Only engine child processes get `MallocLargeCache=0`, so freed large allocations are returned rather than cached. The app's allocator and system settings are unaffected.

Retain this archive, the build recipe, network, `Stockfish-COPYING.txt` and upstream AUTHORS for corresponding-source distribution. The engine remains GPL-3.0-or-later. Source releases retain this archive, recipe and license; app releases carry the signed binary and its exact source/network provenance.
