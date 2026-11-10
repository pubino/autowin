# Install Microsoft 365 Apps with only the apps named, silently and without activating.
# Activation is a sign-in with the user's Microsoft 365 account, done once in the VM window.
#
# Usage (as an administrator or SYSTEM, e.g. through `utmctl exec`):
#   powershell -NoProfile -ExecutionPolicy Bypass -File install-office.ps1 -Apps Access[,Excel,...]
# Writes C:\autowin-office.done (timestamp and installed app paths) or C:\autowin-office.failed.
param(
    [Parameter(Mandatory = $true)][string[]]$Apps,
    [string]$Product = 'O365ProPlusRetail',
    [string]$Channel = 'Current'
)
$ErrorActionPreference = 'Stop'
$work = 'C:\autowin-office'
New-Item -ItemType Directory -Force -Path $work | Out-Null
Remove-Item -Force -ErrorAction SilentlyContinue 'C:\autowin-office.done', 'C:\autowin-office.failed'
Start-Transcript -Path 'C:\autowin-office.log' -Append | Out-Null
# Windows Update started a 4.3 GB download during Office's in a fresh VM. Pause automatic updates
# for the install only; the previous setting is restored in `finally`, even on failure.
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$auBefore = (Get-ItemProperty -Path $au -Name NoAutoUpdate -ErrorAction SilentlyContinue).NoAutoUpdate
try {
    New-Item -Path $au -Force | Out-Null
    Set-ItemProperty -Path $au -Name NoAutoUpdate -Type DWord -Value 1
    Stop-Service wuauserv -Force -ErrorAction SilentlyContinue

    # Office Deployment Tool app IDs; everything not asked for is excluded.
    # With -File, "-Apps Access,Excel" arrives as one string: split it here.
    $Apps = @($Apps | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $all = 'Access', 'Excel', 'Groove', 'Lync', 'OneDrive', 'OneNote', 'Outlook', 'OutlookForWindows',
           'PowerPoint', 'Publisher', 'Teams', 'Word', 'Bing'
    foreach ($a in $Apps) { if ($all -notcontains $a) { throw "unknown Office app: $a" } }
    $exclude = ($all | Where-Object { $Apps -notcontains $_ } | ForEach-Object { "      <ExcludeApp ID=`"$_`" />" }) -join "`r`n"

    $setup = Join-Path $work 'setup.exe'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://officecdn.microsoft.com/pr/wsus/setup.exe' -OutFile $setup
    $sig = Get-AuthenticodeSignature $setup
    if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation') {
        throw "Office Deployment Tool signature is not a valid Microsoft signature ($($sig.Status))"
    }

    # Installing straight from the CDN goes through Delivery Optimization, where Office's main
    # package sat at 0 MB in a UTM VM (also in HTTP-only mode). So: download to a local source
    # first, check it arrived, then install from it without the network.
    $do = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    New-Item -Path $do -Force | Out-Null
    Set-ItemProperty -Path $do -Name DODownloadMode -Type DWord -Value 0
    Restart-Service DoSvc -Force

    $source = Join-Path $work 'source'
    New-Item -ItemType Directory -Force -Path $source | Out-Null
    $config = Join-Path $work 'config.xml'
    @"
<Configuration>
  <Add SourcePath="$source" OfficeClientEdition="64" Channel="$Channel">
    <Product ID="$Product">
      <Language ID="en-us" />
$exclude
    </Product>
  </Add>
  <Property Name="AUTOACTIVATE" Value="0" />
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Updates Enabled="FALSE" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
"@ | Set-Content -Path $config -Encoding UTF8

    $p = Start-Process -FilePath $setup -ArgumentList '/download', $config -WorkingDirectory $work -Wait -PassThru
    Write-Output "Office Deployment Tool /download exit code: $($p.ExitCode)"
    if ($p.ExitCode -ne 0) { throw "Office download failed with exit code $($p.ExitCode)" }
    $cabs = @(Get-ChildItem (Join-Path $source 'Office\Data') -Recurse -Filter *.cab -ErrorAction SilentlyContinue)
    $mb = (Get-ChildItem $source -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
    if ($cabs.Count -eq 0 -or $mb -lt 500) { throw ("Office download is incomplete ({0:N0} MB, {1} cab files)" -f $mb, $cabs.Count) }
    Write-Output ("Office source: {0:N0} MB" -f $mb)

    $p = Start-Process -FilePath $setup -ArgumentList '/configure', $config -WorkingDirectory $work -Wait -PassThru
    Write-Output "Office Deployment Tool /configure exit code: $($p.ExitCode)"
    if ($p.ExitCode -ne 0) { throw "Office install failed with exit code $($p.ExitCode)" }

    # Positive evidence: the executable of every app asked for.
    $exe = @{ Access = 'MSACCESS.EXE'; Excel = 'EXCEL.EXE'; Word = 'WINWORD.EXE'; PowerPoint = 'POWERPNT.EXE';
              Outlook = 'OUTLOOK.EXE'; OneNote = 'ONENOTE.EXE'; Publisher = 'MSPUB.EXE' }
    $found = foreach ($a in $Apps) {
        if (-not $exe.ContainsKey($a)) { continue }
        $hit = Get-ChildItem 'C:\Program Files\Microsoft Office\root' -Recurse -Filter $exe[$a] -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $hit) { throw "$a was not installed ($($exe[$a]) not found)" }
        "$a=$($hit.FullName)"
    }
    Set-Content -Path 'C:\autowin-office.done' -Value ((@(Get-Date -Format o) + $found) -join "`r`n")
}
catch {
    Write-Output "install failed: $_"
    Set-Content -Path 'C:\autowin-office.failed' -Value "$_"
}
finally {
    if ($null -eq $auBefore) { Remove-ItemProperty -Path $au -Name NoAutoUpdate -ErrorAction SilentlyContinue }
    else { Set-ItemProperty -Path $au -Name NoAutoUpdate -Type DWord -Value $auBefore }
    Stop-Transcript | Out-Null
}
