#!/bin/zsh
# Run PowerShell in a VM through the guest agent and print its output. Exit 1 if the code threw.
# Usage: examples/zsh/vm-ps.sh [--timeout SEC] NAME 'POWERSHELL CODE'
#
# The code runs as SYSTEM (gotcha 19). It travels Base64-encoded (-EncodedCommand), so no
# quoting survives or breaks on the way through cmd.exe (gotcha 21). `utmctl exec` returns at
# once (gotcha 22), so the result is a file the guest writes last, waited for and then removed.
set -euo pipefail
UTMCTL=${UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}
timeout=300
if [[ "${1:-}" == --timeout ]]; then timeout=${2:?}; shift 2; fi
name=${1:?usage: vm-ps.sh [--timeout SEC] NAME CODE} code=${2:?usage: vm-ps.sh [--timeout SEC] NAME CODE}
[[ "$name" =~ '^[A-Za-z0-9._-]{1,40}$' ]] || { print -u2 "vm-ps: invalid VM name"; exit 1; }
[[ "$timeout" =~ '^[0-9]+$' ]] || { print -u2 "vm-ps: --timeout must be seconds"; exit 1; }

id="$(date +%s)-$$-$RANDOM"
out="C:\\autowin-ps\\$id.out" fin="C:\\autowin-ps\\$id.done"
wrapper="New-Item -ItemType Directory -Force C:\\autowin-ps | Out-Null
\$status = 0
try { \$r = & { $code } *>&1 | Out-String -Width 240 }
catch { \$r = \"ERROR: \$_\"; \$status = 1 }
Set-Content -Encoding UTF8 -Path '$out' -Value \$r
Set-Content -Path '$fin' -Value \$status"
enc=$(print -rn -- "$wrapper" | iconv -t UTF-16LE | base64 | tr -d '\n')

pull() { perl -e 'alarm shift; exec @ARGV' 60 "$UTMCTL" file pull --hide "$name" "$1" 2>/dev/null || true; }
"$UTMCTL" exec --hide "$name" --cmd powershell.exe -NoProfile -NonInteractive -EncodedCommand "$enc" \
  >/dev/null 2>&1 || true
deadline=$(( SECONDS + timeout ))
until [[ "$(pull "$fin")" =~ '^[01]' ]]; do
  (( SECONDS < deadline )) || { print -u2 "vm-ps: no result after ${timeout}s (is the guest agent running?)"; exit 1; }
  perl -e 'select(undef, undef, undef, 1)'
done
result=$(pull "$fin")
pull "$out" | tr -d '\r' | sed '1s/^\xEF\xBB\xBF//'
"$UTMCTL" exec --hide "$name" --cmd cmd.exe /c "del /q $out $fin" >/dev/null 2>&1 || true
[[ "$result" == 0* ]]
