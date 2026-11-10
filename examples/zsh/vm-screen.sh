#!/bin/zsh
# Save a screenshot of a VM's display as PNG, through its QEMU monitor (screendump).
# Usage: examples/zsh/vm-screen.sh NAME OUT.png
set -euo pipefail
source "${0:A:h}/monitor.zsh"
name=${1:?usage: vm-screen.sh NAME OUT.png} out=${2:?usage: vm-screen.sh NAME OUT.png}
[[ "$name" =~ '^[A-Za-z0-9._-]{1,40}$' ]] || { print -u2 "vm-screen: invalid name"; exit 1; }
dump="$UTM_GROUP/$name.screen.ppm"  # QEMU can only write inside UTM's sandbox
rm -f "$dump"
monitor "$name" 0.2 "screendump $name.screen.ppm" >/dev/null
for _ in {1..20}; do [[ -s "$dump" ]] && break; sleep 0.25; done
[[ -s "$dump" ]] || { print -u2 "vm-screen: QEMU wrote no screenshot"; exit 1; }
python3 "${0:A:h:h}/tools/ppm2png.py" "$dump" "$out" >/dev/null
rm -f "$dump"
print -r -- "$out"
