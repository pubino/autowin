# Sourced by the vm-*.sh scripts: talk to a VM's QEMU monitor (HMP) over its unix socket.
#
# vm-create.sh gives every VM `-monitor unix:NAME.mon,server=on,wait=off`. QEMU runs inside UTM's
# sandbox with UTM's group container as its working directory, so the socket appears there. (An
# absolute path does not work: UTM splits extra arguments at spaces, and the group container's path
# has one.) This is the only reliable way in: UTM's own AppleScript keystrokes never reach the guest.

UTM_GROUP=${UTM_GROUP:-$HOME/Library/Group Containers/WDNLXAD4W8.com.utmapp.UTM}

monitor_socket() { print -r -- "$UTM_GROUP/$1.mon"; }

# monitor NAME DELAY COMMAND...: send each command, DELAY seconds apart; replies on stdout.
monitor() {
  local sock; sock=$(monitor_socket "$1"); local delay=$2; shift 2
  [[ -S "$sock" ]] || { print -u2 -- "no QEMU monitor socket for this VM ($sock); is it running?"; return 1; }
  { local c; for c in "$@"; do print -r -- "$c"; sleep "$delay"; done; sleep 0.5; } | nc -U "$sock"
}

# keys_for TEXT: one `sendkey` per character (US layout), then Enter.
keys_for() {
  local text=$1 ch k; local -a out
  local -A named=(' ' spc ':' shift-semicolon ';' semicolon '\' backslash '/' slash '.' dot ','
    comma '-' minus '_' shift-minus '=' equal '+' shift-equal "'" apostrophe '"' shift-apostrophe)
  for ch in ${(s::)text}; do
    if (( ${+named[$ch]} )); then k=${named[$ch]}
    elif [[ "$ch" == [A-Z] ]]; then k="shift-${(L)ch}"
    elif [[ "$ch" == [a-z0-9] ]]; then k=$ch
    else print -u2 -- "cannot type character: $ch"; return 1
    fi
    out+=("sendkey $k")
  done
  out+=("sendkey ret")
  print -rl -- $out
}
