#!/bin/bash
set -euo pipefail
app=${1:?Pass the prepared app bundle}
entitlements="$(cd "$(dirname "$0")/.." && pwd)/Release.entitlements"
identity=${CHECKMATE_SIGN_ID:-Developer ID Application: HANDO K.K. (Y53RSUA3SM)}
engine=$(find "$app/Contents/Resources" -type f -name stockfish)
[[ -n "$engine" && "$engine" != *$'\n'* ]] || { echo 'Expected one engine' >&2;exit 1; }
# A secure timestamp is a network request. Retry transport failures, then fail loudly.
sign() {
    local attempt
    local options=()
    if [[ "$1" == "$app" ]]; then options+=(--entitlements "$entitlements"); fi
    for attempt in 1 2 3 4 5; do
        if codesign --force --options runtime --timestamp --sign "$identity" "${options[@]}" "$1"; then return; fi
        (( attempt < 5 )) || return 1
        sleep "$attempt"
    done
}
sign "$engine"
# Signing changes the binary bytes; retain both hashes in the shipped provenance.
python3 - "$engine" <<'PY'
import hashlib,json,pathlib,sys
engine=pathlib.Path(sys.argv[1]); manifest=engine.with_name('stockfish-build.json')
data=json.loads(manifest.read_text());data['unsignedBinarySHA256']=data['binarySHA256']
data['binarySHA256']=hashlib.sha256(engine.read_bytes()).hexdigest()
manifest.write_text(json.dumps(data,indent=2)+'\n')
PY
sign "$app"
codesign --verify --deep --strict "$app"
entitlements=$(codesign -d --entitlements :- "$app" 2>/dev/null || true)
[[ "$entitlements" != *get-task-allow* ]] || { echo 'Debugger entitlement in release' >&2;exit 1; }

