#!/bin/zsh
# Clone a stopped VM for throwaway use, with its own QEMU monitor socket and MAC address.
# Usage: examples/zsh/vm-clone.sh [--dry-run] SOURCE NAME
#
# `utmctl clone` copies the configuration as is, so the clone would share the source's monitor
# socket (unix:SOURCE.mon) and MAC address: run side by side, they collide. The clone also shares
# the source's Windows and Office device identity, so vm-destroy.sh keeps a clone's Office license
# by default (releasing it would sign the source out too). Lineage is recorded for that.
set -euo pipefail
UTMCTL=${UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}
PLISTBUDDY=${PLISTBUDDY:-/usr/libexec/PlistBuddy}
UTM_DOCS=${UTM_DOCS:-$HOME/Library/Containers/com.utmapp.UTM/Data/Documents}
STATE_ROOT=${AUTOWIN_STATE:-$HOME/Library/Application Support/autowin}

dry=0
die() { print -ru2 -- "vm-clone: $*"; exit 1; }
say() { print -r -- "vm-clone: $*"; }
run() { if (( dry )); then print -r -- "+ ${(q-)@}"; else "$@"; fi; }
[[ "${1:-}" == --dry-run ]] && { dry=1; shift; }
src=${1:-} name=${2:-}
[[ -n "$src" && -n "$name" ]] || die "usage: vm-clone.sh [--dry-run] SOURCE NAME"
for n in "$src" "$name"; do [[ "$n" =~ '^[A-Za-z0-9._-]{1,40}$' ]] || die "invalid VM name: $n"; done

st=$("$UTMCTL" status "$src" 2>/dev/null) || die "no VM named $src"
[[ "$st" == stopped ]] || die "$src is $st; stop $src first (a running VM cannot be cloned consistently)"
"$UTMCTL" status "$name" >/dev/null 2>&1 && die "a VM named $name already exists"
[[ -e "$UTM_DOCS/$name.utm" ]] && die "$UTM_DOCS/$name.utm already exists"

# Locally administered, unicast MAC: first octet ends in binary 10.
mac=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n' | tr 'a-f' 'A-F' | sed -E 's/(..)/\1:/g; s/:$//')
first=$(( (16#${mac[1,2]} & 0xFC) | 0x02 ))
mac=$(printf '%02X' $first)${mac[3,-1]}

run "$UTMCTL" clone "$src" --name "$name"
cfg="$UTM_DOCS/$name.utm/config.plist"
run "$PLISTBUDDY" -c "Set :QEMU:AdditionalArguments:1 unix:$name.mon,server=on,wait=off" \
  -c "Set :Network:0:MacAddress $mac" "$cfg"
# UTM keeps configurations in memory; without a reload the edits are ignored (gotcha 14).
# The reload reports an error (-2700) but applies the file; the checks below decide.
run osascript -e "tell application \"UTM\" to reload configuration of virtual machine named \"$name\"" \
  >/dev/null 2>&1 || true
if (( ! dry )); then
  [[ "$("$PLISTBUDDY" -c 'Print :QEMU:AdditionalArguments:1' "$cfg")" == "unix:$name.mon,server=on,wait=off" ]] ||
    die "the clone's monitor socket was not changed"
  [[ "$("$PLISTBUDDY" -c 'Print :Network:0:MacAddress' "$cfg")" == "$mac" ]] || die "the clone's MAC was not changed"
  mkdir -p "$STATE_ROOT/$name"
  chmod 700 "$STATE_ROOT" "$STATE_ROOT/$name"
  print -r -- "$src" > "$STATE_ROOT/$name/clone-of"
  [[ -f "$STATE_ROOT/$src/password" ]] && cp -p "$STATE_ROOT/$src/password" "$STATE_ROOT/$name/password"
fi
say "cloned $src to $name (monitor $name.mon, MAC $mac)"
