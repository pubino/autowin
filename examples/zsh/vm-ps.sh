#!/bin/zsh
# Run PowerShell in a VM through the guest agent and print its output. Exit 1 if the code threw.
# Usage: examples/zsh/vm-ps.sh [--timeout SEC] [--user NAME] VM 'POWERSHELL CODE'
#
# By default the code runs as SYSTEM (gotcha 19). With --user it runs in that user's interactive
# desktop session, through a one-time scheduled task (gotcha 32): needed for Office automation
# and anything with a window. The code travels Base64-encoded (-EncodedCommand), so no quoting
# breaks on the way through cmd.exe (gotcha 21). `utmctl exec` returns at once (gotcha 22), so
# the result is a file the guest writes last, waited for and then removed.
set -euo pipefail
UTMCTL=${UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}
timeout=300 user=""
while [[ "${1:-}" == --* ]]; do
  case $1 in
    --timeout) timeout=${2:?}; shift 2 ;;
    --user) user=${2:?}; shift 2 ;;
    *) print -ru2 "vm-ps: unknown option: $1"; exit 1 ;;
  esac
done
name=${1:?usage: vm-ps.sh [--timeout SEC] [--user NAME] VM CODE}
code=${2:?usage: vm-ps.sh [--timeout SEC] [--user NAME] VM CODE}
[[ "$name" =~ '^[A-Za-z0-9._-]{1,40}$' ]] || { print -ru2 "vm-ps: invalid VM name"; exit 1; }
[[ "$timeout" =~ '^[0-9]+$' ]] || { print -ru2 "vm-ps: --timeout must be seconds"; exit 1; }
[[ -z "$user" || "$user" =~ '^[A-Za-z0-9._-]{1,20}$' ]] || { print -ru2 "vm-ps: invalid user name"; exit 1; }

id="$(date +%s)-$$-$RANDOM"
out="C:\\autowin-ps\\$id.out" fin="C:\\autowin-ps\\$id.done"
b64() { print -rn -- "$1" | base64 | tr -d '\n'; }

# body OUT DONE: run the code, capture everything, write the output then the status (last).
body() {
  print -r -- "\$status = 0
try { \$r = & { $code } *>&1 | Out-String -Width 240 }
catch { \$r = \"ERROR: \$_\"; \$status = 1 }
Set-Content -Encoding UTF8 -Path '$1' -Value \$r
Set-Content -Path '$2' -Value \$status"
}

if [[ -z "$user" ]]; then
  wrapper="New-Item -ItemType Directory -Force C:\\autowin-ps | Out-Null
$(body "$out" "$fin")"
else
  udir="C:\\Users\\$user\\AppData\\Local\\autowin-ps"
  inner=$(b64 "$(body "$udir\\$id.out" "$udir\\$id.done")")
  wrapper="New-Item -ItemType Directory -Force C:\\autowin-ps | Out-Null
New-Item -ItemType Directory -Force '$udir' | Out-Null
\$enc = New-Object System.Text.UTF8Encoding \$true
[IO.File]::WriteAllText('$udir\\$id.ps1', [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$inner')), \$enc)
\$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"$udir\\$id.ps1\"'
\$p = New-ScheduledTaskPrincipal -UserId \"\$env:COMPUTERNAME\\$user\" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'autowin-ps-$id' -Action \$a -Principal \$p -Force | Out-Null
Start-ScheduledTask -TaskName 'autowin-ps-$id'
\$deadline = (Get-Date).AddSeconds($timeout)
while (-not (Test-Path '$udir\\$id.done') -and (Get-Date) -lt \$deadline) { Start-Sleep -Milliseconds 500 }
Unregister-ScheduledTask -TaskName 'autowin-ps-$id' -Confirm:\$false
if (Test-Path '$udir\\$id.done') { Copy-Item '$udir\\$id.out' '$out'; Copy-Item '$udir\\$id.done' '$fin' }
else { Set-Content -Path '$out' -Value 'ERROR: no result from the session of $user (is $user logged on?)'; Set-Content -Path '$fin' -Value 1 }
Remove-Item -Force -ErrorAction SilentlyContinue '$udir\\$id.ps1', '$udir\\$id.out', '$udir\\$id.done'"
fi
enc=$(print -rn -- "$wrapper" | iconv -t UTF-16LE | base64 | tr -d '\n')

pull() { perl -e 'alarm shift; exec @ARGV' 60 "$UTMCTL" file pull --hide "$name" "$1" 2>/dev/null || true; }
"$UTMCTL" exec --hide "$name" --cmd powershell.exe -NoProfile -NonInteractive -EncodedCommand "$enc" \
  >/dev/null 2>&1 || true
# With --user the guest side gives up after $timeout and reports; allow it time to do so.
grace=0; [[ -n "$user" ]] && grace=30
deadline=$(( SECONDS + timeout + grace ))
until [[ "$(pull "$fin")" =~ '^[01]' ]]; do
  (( SECONDS < deadline )) || { print -ru2 "vm-ps: no result after ${timeout}s (is the guest agent running?)"; exit 1; }
  perl -e 'select(undef, undef, undef, 1)'
done
result=$(pull "$fin")
pull "$out" | tr -d '\r' | sed '1s/^\xEF\xBB\xBF//'
"$UTMCTL" exec --hide "$name" --cmd cmd.exe /c "del /q $out $fin" >/dev/null 2>&1 || true
[[ "$result" == 0* ]]
