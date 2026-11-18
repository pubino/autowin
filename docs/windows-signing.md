# Sign Windows builds with Azure Artifact Signing

Use a disposable autowin VM and an Azure Artifact Signing profile approved for the software you distribute. The Entra user needs the **Artifact Signing Certificate Profile Signer** role on the certificate profile. Public distribution uses a Public Trust profile. Install Azure CLI and Edge in the guest. Install SignTool, the Artifact Signing client library, and the Visual C++ redistributable for the signing tool's architecture. Use Microsoft's [Artifact Signing setup guide](https://learn.microsoft.com/en-us/azure/artifact-signing/how-to-signing-integrations).

Read `Azure.CodeSigning.Dlib.runtimeconfig.json` beside the signing library and install its required .NET runtime for the same architecture. For example, Artifact Signing Client 1.0.151 specifies .NET 10. On Windows Arm64, an x64 SignTool uses the x64 runtime, normally installed under `C:\Program Files\dotnet\x64`. Set `DOTNET_ROOT_X64` to that directory in the signing process when needed. A missing runtime can make SignTool exit without a diagnostic. [Windows .NET installation](https://learn.microsoft.com/en-us/dotnet/core/install/windows#arm-based-windows-pcs)

## Sign in through Edge in the guest

On the Mac, sign in to Azure CLI as the approved user and select the signing tenant. Run the helper while the Windows build user is logged in.

```zsh
examples/zsh/vm-azure-login.sh --dry-run signing-vm builder
examples/zsh/vm-azure-login.sh signing-vm builder
```

Complete the Microsoft sign-in in the Edge window that opens in the VM. The PowerShell window waits for Edge to finish. Follow your organization's MFA and Conditional Access requirements. The helper verifies the guest's Entra object ID against the Mac's current Azure CLI identity. A matching guest session can be reused. The guest creates its own Azure CLI sign-in cache.

## Sign and verify the build

Run your project's signing command as the same Windows user. With autowin, run PowerShell using `vm-ps.sh --user builder signing-vm`. Provide the regional Azure endpoint, signing account and certificate profile in the client metadata file. Keep the metadata and the build outputs outside version control.

```powershell
$ErrorActionPreference = 'Stop'
& $env:SIGNTOOL sign /fd SHA256 /tr http://timestamp.acs.microsoft.com /td SHA256 `
  /dlib $env:ARTIFACT_SIGNING_DLIB /dmdf $env:ARTIFACT_SIGNING_METADATA $env:INSTALLER
if ($LASTEXITCODE -ne 0) { throw 'Signing failed.' }

& $env:SIGNTOOL verify /pa /tw $env:INSTALLER
if ($LASTEXITCODE -ne 0) { throw 'Signature verification failed.' }

$signature = Get-AuthenticodeSignature -LiteralPath $env:INSTALLER
if ($signature.Status -ne 'Valid' -or -not $signature.TimeStamperCertificate) {
    throw 'A trusted signature and timestamp are required.'
}
Get-FileHash -LiteralPath $env:INSTALLER -Algorithm SHA256
```

Test the signed installer as a standard user. Verify the publisher and timestamp on the installer, installed executables, and any generated uninstaller. Test updates with the finished signed build. Use `utmctl file pull` to retrieve the artifact and compare its SHA-256 with the value from the guest.
