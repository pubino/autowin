#!/bin/zsh
# Install Microsoft 365 Apps (only the apps named) in a VM made by vm-create.sh, unattended.
# Activation is a sign-in with a Microsoft 365 account in the VM window afterwards.
#
# Usage: examples/zsh/vm-office.sh [--dry-run] [--apps Access,Excel] [--timeout MIN] [NAME]
#
# Copies examples/guest/install-office.ps1 into the guest (verified byte for byte), starts it
# through the guest agent and waits for the marker it writes: C:\autowin-office.done lists the
# installed executables; C:\autowin-office.failed holds the reason.
set -euo pipefail
here=${0:A:h}
script=${here:h}/guest/install-office.ps1
UTMCTL=${UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}

name=${AUTOWIN_NAME:-autowin} apps=Access timeout=45 dry=0
die() { print -ru2 -- "vm-office: $*"; exit 1; }  # -r: Windows paths have backslashes
say() { print -r -- "vm-office: $*"; }
while (( $# )); do
  case $1 in
    --dry-run) dry=1 ;;
    --apps) apps=${2:?}; shift ;;
    --timeout) timeout=${2:?}; shift ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) name=$1 ;;
  esac
  shift
done
[[ "$name" =~ '^[A-Za-z0-9._-]{1,40}$' ]] || die "invalid VM name"
[[ "$apps" =~ '^[A-Za-z]+(,[A-Za-z]+)*$' ]] || die "--apps is a comma-separated list such as Access,Excel"
[[ "$timeout" =~ '^[0-9]+$' ]] || die "--timeout must be a number of minutes"
[[ -x "$UTMCTL" ]] || die "UTM not found ($UTMCTL)"
[[ "$("$UTMCTL" status "$name" 2>/dev/null || true)" == started ]] || die "VM $name is not running"

# utmctl exits 0 even when it fails (gotcha 12): every step is checked by what it produced.
pull() { perl -e 'alarm shift; exec @ARGV' 60 "$UTMCTL" file pull --hide "$name" "$1" 2>/dev/null || true; }
guest_dir='C:\autowin-office'
guest_ps1="$guest_dir\\install-office.ps1"

if (( dry )); then
  print -- "+ utmctl exec $name: mkdir $guest_dir"
  print -- "+ utmctl file push $name $guest_ps1 < $script (then verify)"
  print -- "+ utmctl exec $name: install-office.ps1 -Apps $apps (in the background)"
  say "dry run: would wait up to $timeout min for C:\\autowin-office.done"
  exit 0
fi

begin=$SECONDS
"$UTMCTL" exec --hide "$name" --cmd cmd.exe /c "mkdir $guest_dir" >/dev/null 2>&1 || true
"$UTMCTL" file push --hide "$name" "$guest_ps1" < "$script" >/dev/null 2>&1 || true
[[ "$(pull "$guest_ps1")" == "$(<"$script")" ]] || die "copying install-office.ps1 into the guest failed"
# A previous run's markers would be taken as this run's result; the guest script removes them,
# but only once it runs, so check they are gone before waiting.
# `utmctl exec` returns at once and the command runs on (gotcha 22): wait until they are gone.
"$UTMCTL" exec --hide "$name" --cmd cmd.exe /c 'del /f /q C:\autowin-office.done C:\autowin-office.failed' \
  >/dev/null 2>&1 || true
for _ in {1..30}; do
  [[ -z "$(pull 'C:\autowin-office.done')$(pull 'C:\autowin-office.failed')" ]] && break
  sleep 1
done
[[ -z "$(pull 'C:\autowin-office.done')$(pull 'C:\autowin-office.failed')" ]] || die "cannot clear old markers"
# Run PowerShell directly, without quotes: `cmd /c start "" ...` lost its quotes on the way in
# and never started anything (gotcha 21).
"$UTMCTL" exec --hide "$name" --cmd powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$guest_ps1" \
  -Apps "$apps" >/dev/null 2>&1 || true
say "installing Microsoft 365 Apps ($apps); this downloads about 2-3 GB"

deadline=$(( SECONDS + timeout * 60 ))
while true; do
  done_=$(pull 'C:\autowin-office.done')
  if [[ "$done_" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' ]]; then break; fi
  failed=$(pull 'C:\autowin-office.failed')
  [[ -z "$failed" ]] || die "install failed: ${failed//$'\r'/}; see C:\\autowin-office.log in the VM"
  (( SECONDS < deadline )) || die "timed out after $timeout min; see C:\\autowin-office.log in the VM"
  sleep 30
done
elapsed=$(( SECONDS - begin ))
say "installed in $(( elapsed / 60 ))m $(( elapsed % 60 ))s:"
print -r -- "${done_//$'\r'/}" | tail -n +2 | sed 's/^/  /'
say "next: sign in to Microsoft 365 in the VM window (open the app once) to activate it"
