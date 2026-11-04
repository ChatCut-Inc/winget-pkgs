param([Parameter(Mandatory = $true)][string]$Directory)
$ErrorActionPreference = 'Stop'
$release = Get-Content (Join-Path $Directory 'release.json') -Raw | ConvertFrom-Json
$manifest = Join-Path $Directory "manifests/c/ChatCut/ChatCut/$($release.version)"
$installer = $release.platforms.windows.artifacts[0]
if ($env:CI -ne 'true') { throw 'Run installer verification only on a disposable CI Windows machine.' }

function Get-ChatCutInstallation {
  @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') |
    ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } |
    Where-Object { $_.DisplayName -match '^ChatCut(?: \d|$)' }
}
if (@(Get-ChatCutInstallation).Count -ne 0) { throw 'Refusing to modify a pre-existing ChatCut installation.' }

$clientVersion = [version]'0.0'
if (Get-Command winget -ErrorAction SilentlyContinue) {
  $clientVersion = [version]((& winget --version).Trim().TrimStart('v'))
}
if ($clientVersion -lt [version]'1.29.380') {
  # Pin a reviewed stable client: hosted images can lag the manifest schema.
  Install-Module Microsoft.WinGet.Client -Scope CurrentUser -Repository PSGallery -Force
  Repair-WinGetPackageManager -AllUsers -Version '1.29.380' -Force
  $env:PATH += ";$env:LOCALAPPDATA\Microsoft\WindowsApps"
}
winget --version
if ($LASTEXITCODE -ne 0) { throw 'WinGet is unavailable on this runner.' }
winget validate --manifest $manifest
if ($LASTEXITCODE -ne 0) { throw 'WinGet manifest validation failed.' }

$exe = Join-Path $env:RUNNER_TEMP 'chatcut-winget-installer.exe'
Invoke-WebRequest -Uri $installer.url -OutFile $exe
if ((Get-FileHash $exe -Algorithm SHA256).Hash -ne $installer.sha256) { throw 'Installer SHA-256 mismatch.' }
if ((Get-Item $exe).Length -ne $installer.size) { throw 'Installer size mismatch.' }
$signature = Get-AuthenticodeSignature $exe
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN="?ChatCut Inc\.') {
  throw "Invalid ChatCut Authenticode signature: $($signature.Status), $($signature.SignerCertificate.Subject)"
}
Write-Output "Verified installer SHA-256 and signature: $($signature.SignerCertificate.Subject)"

winget settings --enable LocalManifestFiles
if ($LASTEXITCODE -ne 0) { throw 'Cannot enable local manifest installation.' }
try {
  winget install --manifest $manifest --silent --scope user --accept-package-agreements --accept-source-agreements --disable-interactivity
  if ($LASTEXITCODE -ne 0) { throw "WinGet installation failed: $LASTEXITCODE" }
  $entries = @(Get-ChatCutInstallation)
  $entries | Select-Object DisplayName, DisplayVersion, Publisher, PSPath, QuietUninstallString |
    ConvertTo-Json | Tee-Object -FilePath (Join-Path $env:RUNNER_TEMP 'chatcut-winget-arp.json')
  if ($entries.Count -ne 1 -or $entries[0].DisplayName -ne "ChatCut $($release.version)" -or
      $entries[0].DisplayVersion -ne $release.version -or $entries[0].Publisher -ne 'ChatCut' -or
      $entries[0].PSPath -notmatch 'HKEY_CURRENT_USER') {
    throw 'Installed Apps & Features identity/scope differs from the generated manifest. Review metadata before submission.'
  }
  if (-not $entries[0].QuietUninstallString) { throw 'Installer did not register silent uninstall.' }
  $uninstall = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/d', '/s', '/c', $entries[0].QuietUninstallString) -Wait -PassThru
  if ($uninstall.ExitCode -ne 0) { throw "Silent uninstall failed: $($uninstall.ExitCode)" }
  if (@(Get-ChatCutInstallation).Count -ne 0) { throw 'Uninstall left a registered ChatCut installation.' }
} finally {
  winget settings --disable LocalManifestFiles
}
Write-Output 'PASS: WinGet manifest, public installer digest/signature, user install/ARP identity and silent uninstall.'
