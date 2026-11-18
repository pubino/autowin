#!/bin/zsh
# Sign in to Azure CLI in a Windows guest using the Mac's current tenant and user.
set -euo pipefail

usage() { print -ru2 'Usage: vm-azure-login.sh [--dry-run] [--timeout SEC] VM USER'; }
dry_run=0 timeout=360
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --timeout) (( $# >= 2 )) || { usage; exit 2; }; timeout="$2"; shift 2 ;;
    *) usage; exit 2 ;;
  esac
done
if (( $# != 2 )) || [[ ! "$1" =~ '^[A-Za-z0-9._-]{1,40}$' ||
  ! "$2" =~ '^[A-Za-z0-9._-]{1,20}$' || ! "$timeout" =~ '^[1-9][0-9]{0,2}$' ]]; then
  usage
  exit 2
fi
vm="$1" guest_user="$2"
if (( dry_run )); then
  print -r -- "Check the Azure CLI identity for $guest_user on $vm and open Edge if sign-in is needed."
  exit 0
fi

runner="${AUTOWIN_VM_PS:-${0:A:h}/vm-ps.sh}"
if [[ ! -x "$runner" ]] || ! command -v az >/dev/null; then
  print -ru2 'Install Azure CLI on the Mac and configure the autowin guest runner.'
  exit 1
fi
tenant="$(az account show --query tenantId --output tsv --only-show-errors 2>/dev/null)" || tenant=''
principal="$(az ad signed-in-user show --query id --output tsv --only-show-errors 2>/dev/null)" || principal=''
guid='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
if [[ ! "$tenant" =~ "$guid" || ! "$principal" =~ "$guid" ]]; then
  print -ru2 'Sign in to Azure CLI on the Mac as the authorized user and select the signing tenant.'
  exit 1
fi

find_cli="$(cat <<'POWERSHELL'
$cli = @('C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd',
         'C:\Program Files (x86)\Microsoft SDKs\Azure\CLI2\wbin\az.cmd') |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $cli) { throw 'Install Azure CLI in the Windows guest first.' }
$env:AZURE_CORE_COLLECT_TELEMETRY = 'false'
POWERSHELL
)"
probe="$find_cli
\$ErrorActionPreference = 'Continue'
\$user = & \$cli ad signed-in-user show --query id --output tsv --only-show-errors 2>\$null
if (\$LASTEXITCODE -ne 0) { 'AZURE_SIGN_IN_PENDING' }
elseif ((\$user | Select-Object -Last 1).Trim() -ne '$principal') { 'AZURE_SIGN_IN_WRONG_USER' }
else { 'AZURE_SIGN_IN_READY' }"
guest_args=(--user "$guest_user" --timeout 40 "$vm")
deadline=$(( SECONDS + timeout ))
opened=0
while true; do
  result="$("$runner" "${guest_args[@]}" "$probe")"
  case "$result" in
    AZURE_SIGN_IN_READY)
      print -r -- 'PASS: Windows Azure CLI verified the authorized user.'
      exit 0 ;;
    AZURE_SIGN_IN_WRONG_USER)
      print -ru2 'The guest is signed in as a different Azure identity. Sign out in that Windows user session and rerun.'
      exit 1 ;;
    AZURE_SIGN_IN_PENDING) ;;
    *)
      print -ru2 'The Windows guest did not return an Azure sign-in status.'
      exit 1 ;;
  esac
  if (( ! opened )); then
    login="$find_cli
\$tenant = '$tenant'
$(cat <<'POWERSHELL'
$Host.UI.RawUI.WindowTitle = 'autowin Azure sign-in through Edge'
$edge = @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
          'C:\Program Files\Microsoft\Edge\Application\msedge.exe') |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge was not found.' }
$env:BROWSER = '"' + ($edge -replace '\\','/') + '" --new-window %s'
$env:AZURE_CORE_ENABLE_BROKER_ON_WINDOWS = 'false'
$env:AZURE_CORE_LOGIN_EXPERIENCE_V2 = 'off'
$env:AZURE_CORE_ONLY_SHOW_ERRORS = 'false'
Write-Host 'Complete Azure sign-in in the new Edge window.'
& $cli login --tenant $tenant --output none
if ($LASTEXITCODE -eq 0) { Write-Host 'Azure sign-in complete.' }
else { Write-Host 'Azure sign-in did not complete.' }
POWERSHELL
)"
    encoded="$(print -rn -- "$login" | iconv -t UTF-16LE | base64 | tr -d '\n')"
    "$runner" "${guest_args[@]}" "Start-Process 'powershell.exe' -ArgumentList '-NoProfile -NoExit -EncodedCommand $encoded' -WindowStyle Normal | Out-Null" >/dev/null
    print -r -- 'Complete Azure sign-in in the new Edge window in the guest.'
    opened=1
  elif (( SECONDS >= deadline )); then
    print -ru2 'Azure sign-in is still pending in the Windows guest.'
    exit 1
  else
    sleep 5
  fi
done
