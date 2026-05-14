#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CKIWI_XCFRAMEWORK="${ROOT_DIR}/Kiwi/bindings/swift/Artifacts/CKiwi.xcframework"
SOURCE_XCFRAMEWORK="${ROOT_DIR}/Kiwi.xcframework"
PREPARE_CKIWI_SCRIPT="${ROOT_DIR}/Kiwi/bindings/swift/scripts/prepare-ckiwi-xcframework.sh"
MODEL_DIR="${ROOT_DIR}/woorilee/KiwiModels"

if [[ ! -d "${CKIWI_XCFRAMEWORK}" ]]; then
    if [[ -d "${SOURCE_XCFRAMEWORK}" ]]; then
        "${PREPARE_CKIWI_SCRIPT}" "${SOURCE_XCFRAMEWORK}" "${CKIWI_XCFRAMEWORK}"
    else
        cat >&2 <<'MESSAGE'
error: missing Kiwi/bindings/swift/Artifacts/CKiwi.xcframework

Download or build Kiwi.xcframework, then run:
  Kiwi/bindings/swift/scripts/prepare-ckiwi-xcframework.sh /path/to/Kiwi.xcframework
MESSAGE
        exit 1
    fi
fi

missing_model=0
for file in combiningRule.txt cong.mdl default.dict dialect.dict extract.mdl multi.dict nounchr.mdl sj.morph typo.dict; do
    if [[ ! -f "${MODEL_DIR}/${file}" ]]; then
        echo "error: missing Kiwi model file: ${MODEL_DIR}/${file}" >&2
        missing_model=1
    fi
done

if [[ "${missing_model}" -ne 0 ]]; then
    cat >&2 <<'MESSAGE'

Download the Kiwi model files and place them in:
  woorilee/KiwiModels/
MESSAGE
    exit 1
fi

echo "Kiwi artifacts are ready."
