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
    Set-Content -Path 'C:\autowin-setup.done' -Value (Get-Date -Format o)
}
catch {
    Write-Output "setup failed: $_"
    Set-Content -Path 'C:\autowin-setup.failed' -Value "$_"
}
finally {
    Stop-Transcript | Out-Null
}
