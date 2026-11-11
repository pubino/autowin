# Release this VM's Microsoft 365 activation before the VM is deleted (run by vm-destroy.sh as
# SYSTEM). Follows Microsoft's "reset Microsoft 365 Apps activation state" steps:
#   1. sign the user's accounts out of the Web Account Manager (in the user's session),
#   2. remove Office's cached licenses, identities and credentials,
#   3. check that no license is left.
# Writes C:\autowin-license.released (timestamp, counts) or C:\autowin-license.failed.
#
# A local sign-out removes the license from this VM. Whether Microsoft frees the device slot at
# once is decided by their service; the account's device list ("Devices" > "Sign out") is the
# authoritative place to check.
param([string]$User = 'tester')
$ErrorActionPreference = 'Stop'
Remove-Item -Force -ErrorAction SilentlyContinue 'C:\autowin-license.released', 'C:\autowin-license.failed'
$userHome = "C:\Users\$User"
try {
    Get-Process MSACCESS, EXCEL, WINWORD, POWERPNT, OUTLOOK, ONENOTE, MSPUB -ErrorAction SilentlyContinue |
        Stop-Process -Force

    # 1. Web Account Manager sign-out, in the user's interactive session (scheduled task). Right
    #    after start the guest agent answers before the user is logged on: wait for the desktop.
    $desktop = { Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue | Where-Object { $_.UserName -like "*\$User" } }
    for ($i = 0; $i -lt 120 -and -not (& $desktop); $i++) { Start-Sleep -Seconds 1 }
    if (-not (& $desktop)) { throw "$User is not logged on to a desktop" }
    $wam = @'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
function Await($op, [Type]$type) { $t = $asTask.MakeGenericMethod($type).Invoke($null, @($op)); $t.Wait(-1) | Out-Null; $t.Result }
function AwaitAction($op) { ([System.WindowsRuntimeSystemExtensions]::AsTask($op)).Wait(-1) | Out-Null }
$null = [Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager, Windows.Security.Authentication.Web.Core, ContentType = WindowsRuntime]
$null = [Windows.Security.Credentials.WebAccountProvider, Windows.Security.Credentials, ContentType = WindowsRuntime]
$null = [Windows.Security.Authentication.Web.Core.FindAllAccountsResult, Windows.Security.Authentication.Web.Core, ContentType = WindowsRuntime]
$provider = Await ([Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager]::FindAccountProviderAsync('https://login.microsoft.com', 'organizations')) ([Windows.Security.Credentials.WebAccountProvider])
$found = Await ([Windows.Security.Authentication.Web.Core.WebAuthenticationCoreManager]::FindAllAccountsAsync($provider, 'd3590ed6-52b3-4102-aeff-aad2292ab01c')) ([Windows.Security.Authentication.Web.Core.FindAllAccountsResult])
$n = 0
foreach ($a in $found.Accounts) { AwaitAction ($a.SignOutAsync()); $n++ }
Set-Content -Path "$env:LOCALAPPDATA\autowin-wam-signout.txt" -Value $n
'@
    $script = Join-Path $userHome 'AppData\Local\autowin-wam-signout.ps1'
    Set-Content -Path $script -Value $wam -Encoding UTF8
    $result = Join-Path $userHome 'AppData\Local\autowin-wam-signout.txt'
    Remove-Item -Force -ErrorAction SilentlyContinue $result
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
    $principal = New-ScheduledTaskPrincipal -UserId "$env:COMPUTERNAME\$User" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName 'autowin-wam-signout' -Action $action -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName 'autowin-wam-signout'
    for ($i = 0; $i -lt 120 -and -not (Test-Path $result); $i++) { Start-Sleep -Seconds 1 }
    Unregister-ScheduledTask -TaskName 'autowin-wam-signout' -Confirm:$false
    Remove-Item -Force -ErrorAction SilentlyContinue $script
    $signedOut = if (Test-Path $result) { [int](Get-Content $result) } else { -1 }
    Remove-Item -Force -ErrorAction SilentlyContinue $result
    if ($signedOut -lt 0) { throw 'the account sign-out in the user session gave no result within 2 minutes' }

    # 2. Cached licenses, identities and credentials.
    $removed = 0
    foreach ($dir in "$userHome\AppData\Local\Microsoft\Office\Licenses", "$userHome\AppData\Local\Microsoft\Office\16.0\Licensing") {
        if (Test-Path $dir) { $removed += @(Get-ChildItem $dir -Recurse -File).Count; Remove-Item -Recurse -Force $dir }
    }
    $sid = (New-Object System.Security.Principal.NTAccount("$env:COMPUTERNAME\$User")).Translate([System.Security.Principal.SecurityIdentifier]).Value
    foreach ($key in 'Software\Microsoft\Office\16.0\Common\Identity', 'Software\Microsoft\Office\16.0\Common\Licensing') {
        if (Test-Path "Registry::HKEY_USERS\$sid\$key") { Remove-Item -Recurse -Force "Registry::HKEY_USERS\$sid\$key" }
    }

    # 3. Nothing may be left.
    $left = @(Get-ChildItem "$userHome\AppData\Local\Microsoft\Office\Licenses" -Recurse -File -ErrorAction SilentlyContinue).Count
    if ($left -ne 0) { throw "$left license files are still present" }
    Set-Content -Path 'C:\autowin-license.released' -Value ((Get-Date -Format o), "accounts signed out: $signedOut", "license files removed: $removed")
}
catch {
    Set-Content -Path 'C:\autowin-license.failed' -Value "$_"
}
