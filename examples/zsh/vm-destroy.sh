#!/bin/zsh
# Delete a throwaway VM made by vm-create.sh, with its disk and local state. No undo.
# Usage: examples/zsh/vm-destroy.sh [--dry-run] [NAME]   (default NAME: $AUTOWIN_NAME or autowin)
set -euo pipefail

UTMCTL=${UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}
STATE_ROOT=${AUTOWIN_STATE:-$HOME/Library/Application Support/autowin}

dry=0 name=${AUTOWIN_NAME:-autowin}
while (( $# )); do
  case $1 in
    --dry-run) dry=1 ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    -*) print -u2 "vm-destroy: unknown option: $1"; exit 1 ;;
    *) name=$1 ;;
  esac
  shift
done
[[ "$name" =~ '^[A-Za-z0-9._-]{1,40}$' ]] || { print -u2 "vm-destroy: invalid name"; exit 1; }
run() { if (( dry )); then print -- "+ ${(q-)@}"; else "$@"; fi; }

if vm_status=$("$UTMCTL" status "$name" 2>/dev/null); then
  [[ "$vm_status" == stopped ]] || run "$UTMCTL" stop --kill "$name"
  run "$UTMCTL" delete "$name"
else
  print "vm-destroy: no VM named $name in UTM"
fi
state="$STATE_ROOT/$name"
[[ -d "$state" ]] && run rm -rf "$state"
print "vm-destroy: done"
