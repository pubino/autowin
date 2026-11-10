#!/bin/zsh
# Type into a VM through its QEMU monitor (UTM's AppleScript keystrokes never reach the guest).
# Usage: examples/zsh/vm-keys.sh NAME TEXT            type TEXT, then Enter
#        examples/zsh/vm-keys.sh --any-key SEC NAME   press Space every 0.5 s for SEC seconds
set -euo pipefail
source "${0:A:h}/monitor.zsh"
any=0
if [[ "${1:-}" == --any-key ]]; then any=${2:?seconds}; shift 2; fi
name=${1:?usage: vm-keys.sh [--any-key SEC] NAME [TEXT]}
[[ "$name" =~ '^[A-Za-z0-9._-]{1,40}$' ]] || { print -u2 "vm-keys: invalid name"; exit 1; }
if (( any )); then
  [[ "$any" =~ '^[0-9]+$' ]] || { print -u2 "vm-keys: --any-key needs whole seconds"; exit 1; }
  cmds=(); repeat $(( any * 2 )) cmds+=("sendkey spc")
  monitor "$name" 0.5 $cmds >/dev/null
else
  text=${2:?usage: vm-keys.sh NAME TEXT}
  cmds=("${(@f)$(keys_for "$text")}")
  monitor "$name" 0.08 $cmds >/dev/null
fi
