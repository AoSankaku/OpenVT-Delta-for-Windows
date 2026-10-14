[CmdletBinding()]
param([switch]$DeployToProject)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$buildRoot = Join-Path $projectRoot 'bin/windows'
. "$PSScriptRoot/build_support/windows_release_identity.ps1"
$expectedIdentity = Get-WindowsReleaseIdentity -ProjectRoot $projectRoot
$releaseIdentity = Get-Content -LiteralPath (Join-Path $buildRoot 'release.json') -Raw | ConvertFrom-Json
foreach ($identityField in @('productName','revision','branch','executable','pack','architecture')) {
    if ($releaseIdentity.$identityField -ne $expectedIdentity.$identityField) { throw "The Windows build is stale ($identityField). Rebuild before packaging." }
}
if ($releaseIdentity.executable.Length -gt 28) { throw 'The Windows executable filename exceeds 28 characters.' }
$archivePath = Join-Path $projectRoot 'bin/OpenVT-Delta-for-Windows-x64.zip'
$temporaryArchive = Join-Path $projectRoot ('bin/delta-package-' + [guid]::NewGuid().ToString('N') + '.zip')
foreach ($required in @(
    $releaseIdentity.executable, $releaseIdentity.pack, 'release.json',
    'LICENSE.txt', 'README.md', 'DISTRIBUTION.md',
    'license/GODOT_LICENSE.txt', 'license/GODOT_THIRDPARTY_NOTICES.txt',
    'license/GODOT_LOGO_LICENSE.txt',
    'license/LICENSE.mtoon.txt', 'license/LICENSE.fontawesome.txt',
    'license/ui-icons-provenance.json', 'license/native-runtime/provenance.json',
    'openseeface/NOTICE.txt', 'openseeface/CorrespondingSource',
    'CorrespondingSource/native-runtime'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $buildRoot $required))) { throw "Missing distribution file: $required. Run build_windows.ps1 first." }
}
$executableInfo = (Get-Item -LiteralPath (Join-Path $buildRoot $releaseIdentity.executable)).VersionInfo
if ($executableInfo.ProductName -ne 'OpenVT Delta for Windows') { throw 'The executable product name does not match the Delta distribution.' }
$nativeManifest = Get-Content -LiteralPath (Join-Path $buildRoot 'license/native-runtime/provenance.json') -Raw | ConvertFrom-Json
if (@($nativeManifest.missingNoticeFiles).Count -gt 0) { throw 'Native dependency license notices are incomplete. Resolve missingNoticeFiles before distributing.' }
$safeBuildRoot = [IO.Path]::GetFullPath($buildRoot) + [IO.Path]::DirectorySeparatorChar
foreach ($legalText in @($nativeManifest.standaloneLicenseTexts) + @($nativeManifest.supplementalLicenseSources)) {
    $legalPath = [IO.Path]::GetFullPath((Join-Path $buildRoot $legalText.path))
    if (-not $legalPath.StartsWith($safeBuildRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'A license text path escapes the distribution folder.' }
    if (-not (Test-Path -LiteralPath $legalPath) -or (Get-FileHash -LiteralPath $legalPath -Algorithm SHA256).Hash -ne $legalText.sha256) { throw ('Missing or altered license text: ' + $legalText.path) }
}
$nativeSourceRoot = [IO.Path]::GetFullPath((Join-Path $buildRoot 'CorrespondingSource/native-runtime')) + [IO.Path]::DirectorySeparatorChar
if (@($nativeManifest.packages).Count -eq 0) { throw 'The native dependency manifest contains no packages.' }
foreach ($component in @($nativeManifest.packages) + @($nativeManifest.additionalSources)) {
    $sourcePath = [IO.Path]::GetFullPath((Join-Path $nativeSourceRoot $component.sourceArchive))
    if (-not $sourcePath.StartsWith($nativeSourceRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'A native source archive path escapes the distribution source folder.' }
    if (-not (Test-Path -LiteralPath $sourcePath) -or (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne $component.sourceArchiveSha256) { throw ('Missing or altered native source archive: ' + $component.sourceArchive) }
    $noticePaths = if ($component.noticeFiles) { @($component.noticeFiles) } else { @($component.licenseNotice) }
    if ($noticePaths.Count -eq 0 -or -not $noticePaths[0]) { throw 'A native dependency has no license notice.' }
    foreach ($noticePath in $noticePaths) {
        if (-not (Test-Path -LiteralPath (Join-Path $buildRoot $noticePath))) { throw ('Missing native dependency notice: ' + $noticePath) }
    }
}
$rustNoticePath = Join-Path $buildRoot $nativeManifest.rustStandardLibrary.standardLibraryNotice
if (-not (Test-Path -LiteralPath $rustNoticePath) -or (Get-FileHash -LiteralPath $rustNoticePath -Algorithm SHA256).Hash -ne $nativeManifest.rustStandardLibrary.standardLibraryNoticeSha256) { throw 'Missing or altered Rust standard library notice.' }
foreach ($file in Get-ChildItem -LiteralPath $buildRoot -Recurse -File -Force) {
    if ($file.Name -match '\.(model3\.json|moc3|vrm|ovt\.json)$' -or $file.Name -in 'settings.json','default_profile.json','openvt.exe','openvt.pck') {
        throw ('Unexpected personal model, profile, or obsolete executable in build output: ' + $file.FullName)
    }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
try {
    [IO.Compression.ZipFile]::CreateFromDirectory($buildRoot,$temporaryArchive,[IO.Compression.CompressionLevel]::Optimal,$false)
    Move-Item -LiteralPath $temporaryArchive -Destination $archivePath -Force
} finally {
    if (Test-Path -LiteralPath $temporaryArchive) { Remove-Item -LiteralPath $temporaryArchive -Force }
}
if ($DeployToProject) {
    $obsoletePaths = @(Get-ChildItem -LiteralPath $projectRoot -File | Where-Object { $_.Name -match '^(openvt|OpenVT-Delta-for-Windows|OpenVTDelta-.*)\.(exe|pck|console\.exe)$' -and $_.Name -notin @($releaseIdentity.executable,$releaseIdentity.pack) } | ForEach-Object FullName)
    $allExecutables = $obsoletePaths + @((Join-Path $projectRoot $releaseIdentity.executable))
    if (Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -in $allExecutables }) { throw 'The installed application is running. Close it before deploying the new package.' }
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $safeRoot = $projectRoot + [IO.Path]::DirectorySeparatorChar
        foreach ($entry in $archive.Entries) {
            $targetPath = [IO.Path]::GetFullPath((Join-Path $projectRoot $entry.FullName))
            if (-not $targetPath.StartsWith($safeRoot,[StringComparison]::OrdinalIgnoreCase)) { throw ('Unsafe archive entry: ' + $entry.FullName) }
            $firstPart = ($entry.FullName -split '[/\\]')[0]
            if ($firstPart -in '.git','.agents','.codex','bin','thirdparty') { throw ('Protected archive entry: ' + $entry.FullName) }
        }
    } finally { $archive.Dispose() }
    Expand-Archive -LiteralPath $archivePath -DestinationPath $projectRoot -Force
    $verifiedFiles = 0
    foreach ($file in Get-ChildItem -LiteralPath $buildRoot -Recurse -File -Force) {
        $relativePath = $file.FullName.Substring($buildRoot.Length + 1)
        $targetPath = Join-Path $projectRoot $relativePath
        if ((Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash) { throw ('Deployed file mismatch: ' + $relativePath) }
        $verifiedFiles += 1
    }
    foreach ($obsoletePath in $obsoletePaths) {
        if (Test-Path -LiteralPath $obsoletePath) { Remove-Item -LiteralPath $obsoletePath -Force }
    }
    Write-Output ("Deployment verified: $verifiedFiles files")
}
Write-Output ("Distribution ready: $archivePath")
Write-Output ('ZIP SHA256: ' + (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash)
