#!/bin/bash
# Rebuild the unchanged GPL engine for both supported Mac architectures.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/test_host.py --role build 'the Stockfish build' || exit 1
checkmate_resources="$PWD/Sources/CheckmateCore/Resources"
checkmate_archive="$PWD/ThirdParty/Stockfish/sf_19-source.tar.gz"
python3 - "$checkmate_archive" "$checkmate_resources/stockfish-build.json" <<'PY'
import hashlib,json,pathlib,sys
assert hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()==json.load(open(sys.argv[2]))['sourceSHA256']
PY
checkmate_work=$(mktemp -d /tmp/checkmate-stockfish.XXXXXX)
trap 'rm -r "$checkmate_work"' EXIT
for checkmate_slice in arm64 x86_64; do
    mkdir "$checkmate_work/$checkmate_slice"
    tar -xzf "$checkmate_archive" -C "$checkmate_work/$checkmate_slice"
    checkmate_source="$checkmate_work/$checkmate_slice/Stockfish-sf_19/src"
    cp "$checkmate_resources/nn-1a298aa575a0.nnue" "$checkmate_source/"
    checkmate_arch=apple-silicon
    [[ "$checkmate_slice" != x86_64 ]] || checkmate_arch=x86-64
    (cd "$checkmate_source" && CXXFLAGS=-DNNUE_EMBEDDING_OFF make -j4 build ARCH="$checkmate_arch" COMP=clang)
done
lipo -create "$checkmate_work/arm64/Stockfish-sf_19/src/stockfish" "$checkmate_work/x86_64/Stockfish-sf_19/src/stockfish" -output "$checkmate_work/stockfish"
codesign --force --sign - "$checkmate_work/stockfish"
cp "$checkmate_work/stockfish" "$checkmate_resources/stockfish"
python3 - "$checkmate_resources" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path(sys.argv[1]);path=root/'stockfish-build.json';manifest=json.loads(path.read_text())
manifest['binarySHA256']=hashlib.sha256((root/'stockfish').read_bytes()).hexdigest()
manifest['build']='Tools/build-stockfish.sh: CXXFLAGS=-DNNUE_EMBEDDING_OFF make -j4 build ARCH=apple-silicon / ARCH=x86-64 COMP=clang; lipo; ad-hoc codesign'
manifest['architectures']=['arm64','x86_64']
manifest.pop('unsignedBinarySHA256',None)
path.write_text(json.dumps(manifest,indent=2)+'\n')
PY
