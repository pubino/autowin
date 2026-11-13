#!/bin/zsh
# Create a throwaway Windows 11 (Arm64) VM in UTM that installs itself, logs in automatically and
# installs the UTM guest tools, so the host can drive it with `utmctl exec` and `utmctl file`.
#
# Usage: examples/zsh/vm-create.sh [--dry-run] [--name NAME] [--memory MiB] [--cpus N]
#                                       [--disk GiB] [--timeout MIN] [--updates DIR | --no-updates]
#                                       [--updates-timeout MIN] WINDOWS_ARM64_ISO
#
# The ISO is Microsoft's "Windows 11 (multi-edition ISO for Arm64)" or one built by fetchwin.
# Re-running with the same name does not create a second VM: it waits for the existing one. Local
# state (password, provisioning disc) is kept in ~/Library/Application Support/autowin/NAME;
# vm-destroy.sh removes it.
#
# Updates: fetchwin (`--updates download`) leaves the latest update packages in NAME.updates next
# to NAME.iso. If that folder exists (or --updates names one), it goes on the provisioning disc and
# the VM installs it after first logon, restarting as needed; this script waits for that too.
set -euo pipefail
here=${0:A:h}
guest=${here:h}/guest
source "$here/monitor.zsh"

UTMCTL=${UTMCTL:-/Applications/UTM.app/Contents/MacOS/utmctl}
GUEST_TOOLS=${GUEST_TOOLS:-$HOME/Library/Containers/com.utmapp.UTM/Data/Library/Application Support/GuestSupportTools/utm-guest-tools-latest.iso}
STATE_ROOT=${AUTOWIN_STATE:-$HOME/Library/Application Support/autowin}
UTM_DOCS=${UTM_DOCS:-$HOME/Library/Containers/com.utmapp.UTM/Data/Documents}
PLISTBUDDY=${PLISTBUDDY:-/usr/libexec/PlistBuddy}
VM_USER=${AUTOWIN_USER:-tester}

name=${AUTOWIN_NAME:-autowin} memory=${AUTOWIN_MEMORY:-8192} cpus=${AUTOWIN_CPUS:-4} disk=${AUTOWIN_DISK_GB:-64} timeout=${AUTOWIN_TIMEOUT_MIN:-90} dry=0 iso=""
updates="" updates_mode=auto updates_timeout=${AUTOWIN_UPDATES_TIMEOUT_MIN:-120}
die() { print -ru2 -- "vm-create: $*"; exit 1; }  # -r: Windows paths have backslashes
say() { print -r -- "vm-create: $*"; }
run() { if (( dry )); then print -- "+ ${(q-)@}"; else "$@"; fi; }

while (( $# )); do
  case $1 in
    --dry-run) dry=1 ;;
    --name) name=${2:?}; shift ;;
    --memory) memory=${2:?}; shift ;;
    --cpus) cpus=${2:?}; shift ;;
    --disk) disk=${2:?}; shift ;;
    --timeout) timeout=${2:?}; shift ;;
    --updates) updates=${2:?}; updates_mode=explicit; shift ;;
    --no-updates) updates_mode=off ;;
    --updates-timeout) updates_timeout=${2:?}; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    -*) die "unknown option: $1" ;;
    *) [[ -z "$iso" ]] || die "only one ISO"; iso=$1 ;;
  esac
  shift
done

# --- validate (read-only) --------------------------------------------------------------------
[[ "$(uname -m)" == arm64 ]] || die "needs an Apple silicon Mac"
[[ -x "$UTMCTL" ]] || die "UTM not found ($UTMCTL)"
[[ "$name" =~ '^[A-Za-z0-9._-]{1,40}$' ]] || die "--name may use letters, digits, . _ - (max 40)"
for v in memory cpus disk timeout updates_timeout; do [[ "${(P)v}" =~ '^[0-9]+$' ]] || die "--$v must be a number"; done
(( memory >= 4096 )) || die "--memory must be at least 4096 MiB"
(( disk >= 40 )) || die "--disk must be at least 40 GiB"
[[ -n "$iso" && -f "$iso" ]] || die "Windows ISO not found: ${iso:-(none given)}"
iso=${iso:A}
# fetchwin's update folder: NAME.updates beside NAME.iso unless named or turned off.
case $updates_mode in
  auto) [[ -d "${iso:r}.updates" ]] && updates=${iso:r}.updates ;;
  off) updates="" ;;
  explicit) [[ -d "$updates" ]] || die "--updates: not a directory: $updates" ;;
esac
if [[ -n "$updates" ]]; then
  updates=${updates:A}
  hint=""; [[ $updates_mode == auto ]] && hint=" (found beside the ISO; --no-updates skips it)"
  [[ -f "$updates/updates.json" && -f "$updates/Install-FetchwinUpdates.ps1" ]] ||
    die "$updates is not a fetchwin updates folder (needs updates.json and Install-FetchwinUpdates.ps1)$hint"
  msus=("$updates"/Windows1[01].0-KB<->-arm64.msu(N))
  (( $#msus )) || die "$updates has no Arm64 .msu packages$hint"
  other=("$updates"/*.msu(N)); other=(${other:#*-arm64.msu})
  (( ! $#other )) || die "$updates has packages for another architecture: ${other:t}$hint"
fi
[[ -f "$GUEST_TOOLS" ]] || die "UTM guest tools ISO not found; open UTM once to download it ($GUEST_TOOLS)"

mounts=() staging=""
cleanup() {
  for m in $mounts; do hdiutil detach -quiet "$m" 2>/dev/null || true; rmdir "$m" 2>/dev/null || true; done
  [[ -z "$staging" ]] || rm -rf "$staging"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP  # so a killed run still unmounts (EXIT alone does not fire on signals)
mount_ro() {  # mount_ro IMAGE: mounts read-only, sets REPLY to the mount point
  local m; m=$(mktemp -d "${TMPDIR:-/tmp}/autowin.XXXXXX")
  hdiutil attach -quiet -readonly -nobrowse -mountpoint "$m" "$1" || { rmdir "$m"; die "cannot mount $1"; }
  mounts+=("$m"); REPLY=$m
}
unmount() {  # unmount MOUNTPOINT now instead of at exit
  hdiutil detach -quiet "$1" 2>/dev/null || true
  rmdir "$1" 2>/dev/null || true
  mounts=(${mounts:#$1})
}

mount_ro "$iso"; win=$REPLY
[[ -f "$win/efi/boot/bootaa64.efi" ]] || die "not an Arm64 Windows ISO (no efi/boot/bootaa64.efi)"
[[ -f "$win/sources/install.wim" || -f "$win/sources/install.esd" ]] || die "not a Windows install ISO"
[[ -f "$win/efi/microsoft/boot/cdboot_noprompt.efi" ]] || die "the ISO has no efi/microsoft/boot/cdboot_noprompt.efi"
unmount "$win"  # checked; do not hold the ISO for the rest of the run

state="$STATE_ROOT/$name"
exists=0
"$UTMCTL" status "$name" >/dev/null 2>&1 && exists=1

# --- create ----------------------------------------------------------------------------------
begin=$SECONDS
if (( ! exists )); then
  say "creating VM $name (${memory} MiB, $cpus CPUs, $disk GiB disk)"
  run mkdir -p "$state"
  run chmod 700 "$STATE_ROOT" "$state"
  if (( dry )); then
    say "dry run: would build $state/provision.iso (guest tools + Autounattend.xml + setup-guest.ps1)"
    [[ -z "$updates" ]] || say "dry run: would add updates from $updates ($#msus packages) to the disc"
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
    if [[ -n "$updates" ]]; then
      say "adding updates from $updates ($#msus packages, $(( $(du -sk "$updates" | cut -f1) / 1048576 )) GB)"
      cp -c -R "$updates" "$staging/disc/updates" 2>/dev/null || cp -R "$updates" "$staging/disc/updates"
      cp "$guest/apply-updates.ps1" "$staging/disc/apply-updates.ps1"
      print -r -- "$updates" > "$state/updates"
    else
      rm -f "$state/updates"
    fi
    rm -f "$state/provision.iso"
    # UDF as well: ISO9660/Joliet silently cut files at 4 GiB (a cumulative update is larger).
    hdiutil makehybrid -quiet -iso -joliet -udf -default-volume-name AUTOWIN -o "$state/provision.iso" "$staging/disc"
  fi

  if (( dry )); then
    print -- "+ osascript: make QEMU aarch64 VM $name (2 USB CD drives, NVMe disk, shared network)"
    print -- "+ clone $iso and provision.iso into the VM bundle; name them and a QEMU monitor in config.plist"
    print -- "+ $UTMCTL start $name; check both discs with the monitor; press Space at the boot prompt"
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
      if [[ "$("$PLISTBUDDY" -c 'Print :Information:UUID' "$b/config.plist" 2>/dev/null)" == "$vm_id" ]]; then
        bundle=$b
      fi
    done
    [[ -n "$bundle" || ! -d "$UTM_DOCS/$name.utm" ]] || bundle="$UTM_DOCS/$name.utm"
    [[ -n "$bundle" ]] || die "cannot find the bundle of the new VM ($vm_id)"
    cp -c "$iso" "$bundle/Data/windows.iso" 2>/dev/null || cp "$iso" "$bundle/Data/windows.iso"
    cp -c "$state/provision.iso" "$bundle/Data/provision.iso" 2>/dev/null || cp "$state/provision.iso" "$bundle/Data/provision.iso"
    "$PLISTBUDDY" -c "Add :Drive:0:ImageName string windows.iso" \
      -c "Add :Drive:1:ImageName string provision.iso" \
      -c "Delete :QEMU:AdditionalArguments" "$bundle/config.plist" 2>/dev/null || true
    # No TPM: with QEMU:TPMDevice set here, the installed Windows hangs at the firmware splash
    # (the installer runs fine). The answer file bypasses Windows 11's TPM check instead.
    "$PLISTBUDDY" -c "Add :QEMU:AdditionalArguments array" -c "Add :QEMU:AdditionalArguments:0 string -monitor" \
      -c "Add :QEMU:AdditionalArguments:1 string unix:$name.mon,server=on,wait=off" "$bundle/config.plist"
    # UTM keeps the configuration it created in memory: without a reload it starts the VM with
    # empty CD drives. The reload reports an error (-2700) but applies the file.
    osascript -e "tell application \"UTM\" to reload configuration of virtual machine id \"$vm_id\"" \
      >/dev/null 2>&1 || true
    "$UTMCTL" start "$name"

    # Positive evidence that the discs are in: ask QEMU itself, not the configuration.
    blocks=""
    for _ in {1..30}; do
      blocks=$(monitor "$name" 0.2 "info block" 2>/dev/null || true)
      [[ "$blocks" == *windows.iso* && "$blocks" == *provision.iso* ]] && break
      sleep 1
    done
    [[ "$blocks" == *windows.iso* && "$blocks" == *provision.iso* ]] ||
      die "the VM started without its discs (QEMU reports no windows.iso/provision.iso)"

    # "Press any key to boot from CD or DVD": UTM's AppleScript keystrokes never reach the guest,
    # so press Space through the monitor. If the prompt was missed the firmware drops to Shell>;
    # start the CD's boot loader from there. Setup writing to the disk is the evidence it started.
    # Never send keys once it has: Space would press Setup's focused Cancel button.
    qcow=("$bundle"/Data/*.qcow2(N))
    disk_mb() { print -- $(( $(du -k "$qcow[1]" | cut -f1) / 1024 )); }
    # The prompt appears some seconds after start (the firmware tries the CD first); 20 s was too
    # short. Setup itself only appears well after 45 s, so the burst cannot reach its Cancel button.
    "$here/vm-keys.sh" --any-key 45 "$name"
    started=0
    for attempt in 1 2 3; do
      for _ in {1..36}; do
        (( $(disk_mb) > 1024 )) && { started=1; break; }
        sleep 5
      done
      (( started )) && break
      say "Setup has not started (attempt $attempt); starting the CD's boot loader from the firmware shell"
      "$here/vm-keys.sh" "$name" 'fs0:\efi\boot\bootaa64.efi'
      "$here/vm-keys.sh" --any-key 45 "$name"
    done
    (( started )) || die "Windows Setup did not start; look with: $here/vm-screen.sh $name screen.png"
  fi
else
  say "VM $name already exists; waiting for it"
  if [[ "$("$UTMCTL" status "$name" 2>/dev/null)" != started ]]; then
    run "$UTMCTL" start "$name"
  fi
fi

# --- wait until logged in with guest tools ---------------------------------------------------
if (( dry )); then
  say "dry run: would wait up to $timeout min for the guest agent"
  [[ -z "$updates" ]] || say "dry run: then up to $updates_timeout min for the updates"
  exit 0
fi
# utmctl exits 0 even when the guest agent is not running (it only prints an error), so its exit
# code proves nothing. Readiness is positive evidence instead: the marker file that setup-guest.ps1
# writes, pulled through the agent, holding the timestamp it wrote.
pull() {  # pull GUEST_PATH: the file's contents on stdout, empty if unavailable
  perl -e 'alarm shift; exec @ARGV' 60 "$UTMCTL" file pull --hide "$name" "$1" 2>/dev/null || true
}
probe() { [[ "$(pull 'C:\autowin-setup.done')" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' ]]; }
failed() { [[ -n "$(pull 'C:\autowin-setup.failed')" ]]; }
deadline=$(( SECONDS + timeout * 60 ))
say "installing Windows; this takes about 8 minutes (watch it in the UTM window)"
until probe; do
  (( SECONDS < deadline )) || die "timed out after $timeout min; check the VM window"
  if failed; then die "first-logon setup failed; see C:\\autowin-setup.log in the VM"; fi
  sleep 30
done
# Updates, if the disc had them: the guest installs them from a startup task, restarting as
# needed (the agent is unreachable meanwhile, so empty pulls just mean "not yet").
if [[ -f "$state/updates" ]]; then
  say "installing updates from $(<"$state/updates"); the VM restarts on its own (up to $updates_timeout min)"
  deadline=$(( SECONDS + updates_timeout * 60 ))
  while true; do
    upd=$(pull 'C:\autowin-updates.done')
    [[ "$upd" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' ]] && break
    upd_failed=$(pull 'C:\autowin-updates.failed')
    [[ -z "$upd_failed" ]] || die "updates failed: ${upd_failed//$'\r'/}; the VM is usable. See C:\\autowin-updates.log and C:\\ProgramData\\fetchwin\\install-updates.log"
    (( SECONDS < deadline )) || die "updates not finished after $updates_timeout min; see C:\\autowin-updates.log in the VM"
    sleep 30
  done
  say "updates installed: ${${upd//$'\r'/}#*$'\n'}"
fi
elapsed=$(( SECONDS - begin ))
say "ready: $name is logged in as $VM_USER and answers utmctl exec (built in $(( elapsed / 60 ))m $(( elapsed % 60 ))s)"
say "password: $state/password"
