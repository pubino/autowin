#!/bin/zsh
# Delete a VM made by vm-create.sh or vm-clone.sh, with its disk and local state. No undo.
# Usage: examples/zsh/vm-destroy.sh [--dry-run] [--keep-license|--release-license] [NAME]
#        (default NAME: $AUTOWIN_NAME or autowin)
#
# Before deleting, a VM's Microsoft 365 activation is released inside Windows
# (examples/guest/release-office.ps1), starting the VM if needed, so the license does not stay
# tied to a VM that no longer exists. A clone made by vm-clone.sh keeps it by default: it shares
# its source's device identity, so releasing it would sign the source out too. If the release
# fails, the VM is not deleted.
set -euo pipefail
here=${0:A:h}
release_ps1=${here:h}/guest/release-office.ps1
UTMCTL=${UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}
STATE_ROOT=${AUTOWIN_STATE:-$HOME/Library/Application Support/autowin}
VM_USER=${AUTOWIN_USER:-tester}

dry=0 name=${AUTOWIN_NAME:-autowin} license=auto
die() { print -ru2 -- "vm-destroy: $*"; exit 1; }
say() { print -r -- "vm-destroy: $*"; }
run() { if (( dry )); then print -r -- "+ ${(q-)@}"; else "$@"; fi; }
while (( $# )); do
  case $1 in
    --dry-run) dry=1 ;;
    --keep-license) license=keep ;;
    --release-license) license=release ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) name=$1 ;;
  esac
  shift
done
[[ "$name" =~ '^[A-Za-z0-9._-]{1,40}$' ]] || die "invalid name"
state="$STATE_ROOT/$name"

if [[ "$license" == auto ]]; then
  clones=()
  for f in "$STATE_ROOT"/*/clone-of(N); do [[ "$(<"$f")" == "$name" ]] && clones+=("${f:h:t}"); done
  if [[ -f "$state/clone-of" ]]; then
    license=keep
    say "keeping the Office license: $name is a clone of $(<"$state/clone-of") and shares its device" \
      "identity (--release-license releases it anyway, which signs the source out too)"
  elif (( ${#clones} )); then
    license=keep
    say "keeping the Office license: $name has clones (${(j:, :)clones}) that share its device" \
      "identity (--release-license releases it anyway, which signs them out too)"
  else
    license=release
  fi
fi

pull() { perl -e 'alarm shift; exec @ARGV' 60 "$UTMCTL" file pull --hide "$name" "$1" 2>/dev/null || true; }

release_license() {
  if (( dry )); then
    print -r -- "+ start $name if stopped; count Office license files for $VM_USER"
    print -r -- "+ utmctl file push $name C:\\autowin-office\\release-office.ps1 (verified); run it; wait for its marker"
    return
  fi
  if [[ "$("$UTMCTL" status "$name")" != started ]]; then
    say "starting $name to release its Office license"
    "$UTMCTL" start --hide "$name" >/dev/null 2>&1 || true
  fi
  # Ready once the guest agent answers with the setup marker (utmctl exits 0 even when it fails).
  local deadline=$(( SECONDS + 300 ))
  until [[ "$(pull 'C:\autowin-setup.done')" =~ '^[0-9]{4}-' ]]; do
    (( SECONDS < deadline )) || die "$name did not answer within 5 minutes; nothing deleted"
    sleep 5
  done
  local count
  count=$("$here/vm-ps.sh" "$name" "# AUTOWIN_COUNT_LICENSES
@(Get-ChildItem 'C:\\Users\\$VM_USER\\AppData\\Local\\Microsoft\\Office\\Licenses' -Recurse -File -ErrorAction SilentlyContinue).Count" |
    tr -dc '0-9') || die "could not check $name for an Office license; nothing deleted"
  [[ -n "$count" ]] || die "could not check $name for an Office license; nothing deleted"
  if [[ "$count" == 0 ]]; then
    say "no Office license in $name; nothing to release"
    return
  fi
  local guest_ps1='C:\autowin-office\release-office.ps1'
  "$UTMCTL" exec --hide "$name" --cmd cmd.exe /c 'mkdir C:\autowin-office' >/dev/null 2>&1 || true
  "$UTMCTL" file push --hide "$name" "$guest_ps1" < "$release_ps1" >/dev/null 2>&1 || true
  [[ "$(pull "$guest_ps1")" == "$(<"$release_ps1")" ]] || die "copying release-office.ps1 failed; nothing deleted"
  "$UTMCTL" exec --hide "$name" --cmd powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$guest_ps1" \
    -User "$VM_USER" >/dev/null 2>&1 || true
  deadline=$(( SECONDS + 180 ))
  local done_ failed
  while true; do
    done_=$(pull 'C:\autowin-license.released')
    [[ "$done_" =~ '^[0-9]{4}-' ]] && break
    failed=$(pull 'C:\autowin-license.failed')
    [[ -z "$failed" ]] || die "releasing the Office license failed: ${failed//$'\r'/}; nothing deleted" \
      "(--keep-license deletes anyway)"
    (( SECONDS < deadline )) || die "no result from the license release within 3 minutes; nothing deleted"
    sleep 3
  done
  done_=${done_//$'\r'/}
  say "released the Office license in $name (${done_//$'\n'/; })"
  say "Microsoft's account device list is authoritative: check it, and sign the device out if it is listed"
}

if vm_status=$("$UTMCTL" status "$name" 2>/dev/null); then
  [[ "$license" == release ]] && release_license
  [[ "$("$UTMCTL" status "$name" 2>/dev/null || true)" == stopped ]] || run "$UTMCTL" stop --kill "$name"
  run "$UTMCTL" delete "$name"
else
  say "no VM named $name in UTM"
fi
[[ -d "$state" ]] && run rm -rf "$state"
say "done"
