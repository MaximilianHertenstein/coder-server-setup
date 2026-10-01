#!/bin/bash
# Gibt Shell-Quellen zeilennumeriert aus – vor allem, um die Ausgabe einem
# Chatbot zu geben (Marker je Datei, Zeilennummern fuer Referenzen).
# Standard: setup-coder.sh + ssh-harden.sh + scripts/*.sh
# Teilmengen: ./show-sources.sh tests/*.sh  bzw.  ./show-sources.sh setup-coder.sh
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -gt 0 ]; then
  files=("$@")
else
  files=("${DIR}/setup-coder.sh" "${DIR}/ssh-harden.sh" "${DIR}"/scripts/*.sh)
fi

for f in "${files[@]}"; do
  printf '===== %s =====\n' "${f#"${DIR}"/}"
  nl -ba "${f}"
done
