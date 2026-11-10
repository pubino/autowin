#!/bin/zsh
# Create a throwaway Windows 11 (Arm64) VM in UTM that installs itself, logs in automatically and
# installs the UTM guest tools, so the host can drive it with `utmctl exec` and `utmctl file`.
#
# Usage: examples/zsh/vm-create.sh [--dry-run] [--name NAME] [--memory MiB] [--cpus N]
#                                       [--disk GiB] [--timeout MIN] WINDOWS_ARM64_ISO
#
# The ISO is Microsoft's "Windows 11 (multi-edition ISO for Arm64)". Re-running with the same name
# does not create a second VM: it waits for the existing one. Local state (password, provisioning
# disc) is kept in ~/Library/Application Support/autowin/NAME; vm-destroy.sh removes it.
set -euo pipefail
guest=${0:A:h:h}/guest

UTMCTL=${UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}
GUEST_TOOLS=${GUEST_TOOLS:-$HOME/Library/Containers/com.utmapp.UTM/Data/Library/Application Support/GuestSupportTools/utm-guest-tools-latest.iso}
STATE_ROOT=${AUTOWIN_STATE:-$HOME/Library/Application Support/autowin}
UTM_DOCS=${UTM_DOCS:-$HOME/Library/Containers/com.utmapp.UTM/Data/Documents}
VM_USER=${AUTOWIN_USER:-tester}

name=${AUTOWIN_NAME:-autowin} memory=${AUTOWIN_MEMORY:-8192} cpus=${AUTOWIN_CPUS:-4} disk=${AUTOWIN_DISK_GB:-64} timeout=${AUTOWIN_TIMEOUT_MIN:-90} dry=0 iso=""
die() { print -u2 -- "vm-create: $*"; exit 1; }
say() { print -- "vm-create: $*"; }
run() { if (( dry )); then print -- "+ ${(q-)@}"; else "$@"; fi; }

while (( $# )); do
  case $1 in
    --dry-run) dry=1 ;;
    --name) name=${2:?}; shift ;;
    --memory) memory=${2:?}; shift ;;
    --cpus) cpus=${2:?}; shift ;;
    --disk) disk=${2:?}; shift ;;
    --timeout) timeout=${2:?}; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z "$iso" ]] || die "only one ISO"; iso=$1 ;;
  esac
  shift
done

# --- validate (read-only) --------------------------------------------------------------------
[[ "$(uname -m)" == arm64 ]] || die "needs an Apple silicon Mac"
[[ -x "$UTMCTL" ]] || die "UTM not found ($UTMCTL)"
[[ "$name" =~ '^[A-Za-z0-9._-]{1,40}$' ]] || die "--name may use letters, digits, . _ - (max 40)"
for v in memory cpus disk timeout; do [[ "${(P)v}" =~ '^[0-9]+$' ]] || die "--$v must be a number"; done
(( memory >= 4096 )) || die "--memory must be at least 4096 MiB"
(( disk >= 40 )) || die "--disk must be at least 40 GiB"
[[ -n "$iso" && -f "$iso" ]] || die "Windows ISO not found: ${iso:-(none given)}"
iso=${iso:A}
[[ -f "$GUEST_TOOLS" ]] || die "UTM guest tools ISO not found; open UTM once to download it ($GUEST_TOOLS)"

mounts=() staging=""
cleanup() {
  for m in $mounts; do hdiutil detach -quiet "$m" 2>/dev/null || true; rmdir "$m" 2>/dev/null || true; done
  [[ -z "$staging" ]] || rm -rf "$staging"
}
trap cleanup EXIT
mount_ro() {  # mount_ro IMAGE: mounts read-only, sets REPLY to the mount point
  local m; m=$(mktemp -d "${TMPDIR:-/tmp}/autowin.XXXXXX")
  hdiutil attach -quiet -readonly -nobrowse -mountpoint "$m" "$1" || { rmdir "$m"; die "cannot mount $1"; }
  mounts+=("$m"); REPLY=$m
}

mount_ro "$iso"; win=$REPLY
[[ -f "$win/efi/boot/bootaa64.efi" ]] || die "not an Arm64 Windows ISO (no efi/boot/bootaa64.efi)"
[[ -f "$win/sources/install.wim" || -f "$win/sources/install.esd" ]] || die "not a Windows install ISO"

state="$STATE_ROOT/$name"
exists=0
"$UTMCTL" status "$name" >/dev/null 2>&1 && exists=1

# --- create ----------------------------------------------------------------------------------
if (( ! exists )); then
  say "creating VM $name (${memory} MiB, $cpus CPUs, $disk GiB disk)"
  run mkdir -p "$state"
  run chmod 700 "$STATE_ROOT" "$state"
  if (( dry )); then
    say "dry run: would build $state/provision.iso (guest tools + Autounattend.xml + setup-guest.ps1)"
  elif [[ -f "$state/password" ]]; then
    password=$(<"$state/password")
  else
    password=$(openssl rand -hex 12)
    (umask 077; print -rn -- "$password" > "$state/password")
  fi
  if (( ! dry )); then

    # One provisioning disc: UTM's guest tools and drivers plus our answer file and first-logon script.
    mount_ro "$GUEST_TOOLS"; tools=$REPLY
    staging=$(mktemp -d "${TMPDIR:-/tmp}/autowin-iso.XXXXXX")  # removed on exit
    ditto "$tools" "$staging/disc"
    chmod -R u+w "$staging/disc"
    sed -e "s/@@USER@@/$VM_USER/g" -e "s/@@PASSWORD@@/$password/g" -e "s/@@COMPUTER@@/AUTOWIN-VM/g" \
      "$guest/autounattend.xml" > "$staging/disc/Autounattend.xml"
    cp "$guest/setup-guest.ps1" "$staging/disc/setup-guest.ps1"
    rm -f "$state/provision.iso"
    hdiutil makehybrid -quiet -iso -joliet -default-volume-name AUTOWIN -o "$state/provision.iso" "$staging/disc"
  fi

  if (( dry )); then
    print -- "+ osascript: make QEMU aarch64 VM $name (2 USB CD drives, NVMe disk, shared network)"
    print -- "+ clone $iso and provision.iso into the VM bundle; name them in config.plist; enable TPM"
    print -- "+ $UTMCTL start $name; press a key at the boot prompt"
  else
    vm_id=$(osascript - "$name" "$memory" "$cpus" $(( disk * 1024 )) <<'APPLESCRIPT'
on run argv
  set {vmName, memMiB, cpuCount, diskMiB} to argv
  tell application "UTM"
    set vm to make new virtual machine with properties {backend:qemu, configuration:{name:vmName, architecture:"aarch64", memory:(memMiB as integer), cpu cores:(cpuCount as integer), hypervisor:true, uefi:true, drives:{{removable:true, interface:USB}, {removable:true, interface:USB}, {interface:NVMe, guest size:(diskMiB as integer)}}, network interfaces:{{mode:shared}}, displays:{{hardware:"virtio-ramfb"}}}}
    return id of vm
  end tell
end run
APPLESCRIPT
)
    # AppleScript cannot attach disc images to removable drives (UTM keeps those as sandbox
    # bookmarks made in its GUI). An image inside the VM bundle can be named in its config instead;
    # cloning it in costs no space on APFS.
    bundle=""
    for b in "$UTM_DOCS"/*.utm(N); do
      if [[ "$(/usr/libexec/PlistBuddy -c 'Print :Information:UUID' "$b/config.plist" 2>/dev/null)" == "$vm_id" ]]; then
        bundle=$b
      fi
    done
    [[ -n "$bundle" || ! -d "$UTM_DOCS/$name.utm" ]] || bundle="$UTM_DOCS/$name.utm"
    [[ -n "$bundle" ]] || die "cannot find the bundle of the new VM ($vm_id)"
    cp -c "$iso" "$bundle/Data/windows.iso" 2>/dev/null || cp "$iso" "$bundle/Data/windows.iso"
    cp -c "$state/provision.iso" "$bundle/Data/provision.iso" 2>/dev/null || cp "$state/provision.iso" "$bundle/Data/provision.iso"
    /usr/libexec/PlistBuddy -c "Add :Drive:0:ImageName string windows.iso" \
      -c "Add :Drive:1:ImageName string provision.iso" -c "Set :QEMU:TPMDevice true" "$bundle/config.plist"
    "$UTMCTL" start "$name"
    # Windows Setup asks "Press any key to boot from CD or DVD" for a few seconds.
    osascript - "$name" <<'APPLESCRIPT'
on run argv
  tell application "UTM"
    set vm to virtual machine named (item 1 of argv)
    repeat 25 times
      delay 1
      try
        input keystroke vm text " "
      end try
    end repeat
  end tell
end run
APPLESCRIPT
  fi
else
  say "VM $name already exists; waiting for it"
  if [[ "$("$UTMCTL" status "$name" 2>/dev/null)" != started ]]; then
    run "$UTMCTL" start "$name"
  fi
fi

# --- wait until logged in with guest tools ---------------------------------------------------
(( dry )) && { say "dry run: would wait up to $timeout min for the guest agent"; exit 0; }
probe() {  # exit 0 once the guest agent runs commands and first-logon setup has finished
  perl -e 'alarm shift; exec @ARGV' 60 \
    "$UTMCTL" exec --hide "$name" --cmd cmd.exe /c 'if exist C:\autowin-setup.done (exit 0) else (exit 1)' \
    >/dev/null 2>&1
}
failed() {
  perl -e 'alarm shift; exec @ARGV' 60 \
    "$UTMCTL" exec --hide "$name" --cmd cmd.exe /c 'if exist C:\autowin-setup.failed (exit 0) else (exit 1)' \
    >/dev/null 2>&1
}
deadline=$(( SECONDS + timeout * 60 ))
say "installing Windows; this usually takes 20-30 minutes (watch it in the UTM window)"
until probe; do
  (( SECONDS < deadline )) || die "timed out after $timeout min; check the VM window"
  if failed; then die "first-logon setup failed; see C:\\autowin-setup.log in the VM"; fi
  sleep 30
done
say "ready: $name is logged in as $VM_USER and answers utmctl exec"
say "password: $state/password"
