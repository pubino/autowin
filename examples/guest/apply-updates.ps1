# Install the update packages from fetchwin (https://github.com/pubino/fetchwin) in an autowin VM.
# setup-guest.ps1 copies them to C:\autowin-updates and registers this script as the startup task
# 'autowin-updates' (SYSTEM), then starts it. Each run calls fetchwin's Install-FetchwinUpdates.ps1:
#   exit 0     -> the OS is at the target build: remove the task, write C:\autowin-updates.done
#   exit 3010  -> restart; the task runs this again at startup
#   otherwise  -> remove the task, write C:\autowin-updates.failed
# Install-FetchwinUpdates.ps1 verifies each package (SHA-256, Microsoft signature), installs the
# target cumulative update (DISM takes the checkpoints it needs from the same folder), keeps its
# progress in C:\ProgramData\fetchwin and gives up after a few restarts, so this loop ends.
# Its log: C:\ProgramData\fetchwin\install-updates.log.
param([string]$Dir = 'C:\autowin-updates')
$ErrorActionPreference = 'Stop'
$task = 'autowin-updates'
Start-Transcript -Path 'C:\autowin-updates.log' -Append | Out-Null
try {
    $installer = Join-Path $Dir 'Install-FetchwinUpdates.ps1'
    if (-not (Test-Path -LiteralPath $installer)) { throw "Install-FetchwinUpdates.ps1 not found in $Dir" }
    # A child process: the installer ends with `exit CODE`, which is its result.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Path $Dir
    $code = $LASTEXITCODE
    Write-Output "Install-FetchwinUpdates exit code: $code"
    if ($code -eq 3010) {
        Write-Output 'restarting to continue'
        Restart-Computer -Force
        return
    }
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    if ($code -ne 0) {
        throw "Install-FetchwinUpdates.ps1 exited $code; see C:\ProgramData\fetchwin\install-updates.log"
    }
    $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    Set-Content -Path 'C:\autowin-updates.done' -Value ("{0}`r`nbuild={1}.{2}" -f (Get-Date -Format o), $cv.CurrentBuild, $cv.UBR)
}
catch {
    Write-Output "updates failed: $_"
    Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
    Set-Content -Path 'C:\autowin-updates.failed' -Value "$_"
}
finally {
    Stop-Transcript | Out-Null
}
