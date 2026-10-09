# Stockfish 19 reproducible packaging

The source archive is the unmodified official `sf_19` tag. Check `Resources/stockfish-build.json` for its SHA256 and the binary/network hashes. Compile only on build-host:

```sh
tar -xzf sf_19-source.tar.gz
cd Stockfish-sf_19/src
CXXFLAGS=-DNNUE_EMBEDDING_OFF make -j4 build ARCH=apple-silicon COMP=clang
```

Copy the resulting `stockfish` and the official `nn-1a298aa575a0.nnue` from `https://tests.stockfishchess.org/api/nn/nn-1a298aa575a0.nnue` beside each other in CheckmateCore's Resources. The network's complete expected SHA256 is in the manifest and validated before use. No evaluation, search, or neural-network changes are made. External packaging removes the permanently resident compressed embedded copy. Only engine child processes get `MallocLargeCache=0`, so freed large allocations are returned rather than cached. The app's allocator and system settings are unaffected.

Retain this archive, the build recipe, network, `Stockfish-COPYING.txt` and upstream AUTHORS for corresponding-source distribution. The engine remains GPL-3.0-only. Source releases retain this archive, recipe and license; app releases carry the signed binary and its exact source/network provenance.
