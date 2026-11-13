# First-logon setup for a throwaway autowin VM (run by autounattend.xml from the provisioning disc).
# Installs the UTM guest tools silently, so the host can run commands and copy files (utmctl exec/file).
$ErrorActionPreference = 'Stop'
Start-Transcript -Path 'C:\autowin-setup.log' -Append | Out-Null
try {
    $root = Split-Path -Parent $MyInvocation.MyCommand.Path

    # The virtio drivers are signed by Red Hat. Trusting that publisher first keeps the silent
    # install from stopping at "Would you like to install this device software?".
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher', 'LocalMachine')
    $store.Open('ReadWrite')
    Get-ChildItem (Join-Path $root 'Drivers') -Recurse -Filter *.cat |
        Where-Object { $_.FullName -match '\\w11\\ARM64\\' } |
        ForEach-Object {
            $cert = (Get-AuthenticodeSignature $_.FullName).SignerCertificate
            if ($cert) { $store.Add($cert) }
        }
    $store.Close()

    $exe = Get-ChildItem $root -Filter 'utm-guest-tools-*.exe' | Select-Object -First 1
    if (-not $exe) { throw 'utm-guest-tools installer not found on the provisioning disc' }
    $p = Start-Process -FilePath $exe.FullName -ArgumentList '/S' -Wait -PassThru
    Write-Output "guest tools installer exit code: $($p.ExitCode)"

    powercfg -H OFF
    net accounts /maxpwage:unlimited | Out-Null

    # Optional: fetchwin's update packages on the disc (vm-create.sh puts them in updates\).
    # Copied to the local disk (the task runs again after restarts), then installed by the
    # 'autowin-updates' startup task. A failure here is the updates' failure, not setup's.
    $updates = Join-Path $root 'updates'
    if (Test-Path -LiteralPath (Join-Path $updates 'updates.json')) {
        try {
            $dest = 'C:\autowin-updates'
            Remove-Item -Force -ErrorAction SilentlyContinue 'C:\autowin-updates.done', 'C:\autowin-updates.failed'
            robocopy $updates $dest /E /NFL /NDL /NJH /NJS /NP | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "copying the updates to $dest failed (robocopy exit $LASTEXITCODE)" }
            Copy-Item -Force (Join-Path $root 'apply-updates.ps1') $dest
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
                -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$dest\apply-updates.ps1`" -Dir `"$dest`""
            $trigger = New-ScheduledTaskTrigger -AtStartup
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 4)
            Register-ScheduledTask -TaskName 'autowin-updates' -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Force | Out-Null
            Start-ScheduledTask -TaskName 'autowin-updates'
            Write-Output 'updates: copied; the autowin-updates task is installing them'
        }
        catch {
            Write-Output "updates failed: $_"
            Set-Content -Path 'C:\autowin-updates.failed' -Value "$_"
        }
    }
    Set-Content -Path 'C:\autowin-setup.done' -Value (Get-Date -Format o)
}
catch {
    Write-Output "setup failed: $_"
    Set-Content -Path 'C:\autowin-setup.failed' -Value "$_"
}
finally {
    Stop-Transcript | Out-Null
}
