[CmdletBinding()]
param(
    [string]$Godot = "$PSScriptRoot/bin/godot/godot.windows.editor.x86_64.console.exe",
    [string]$Template = "$PSScriptRoot/bin/godot/windows_release_x86_64.exe",
    [switch]$SkipDependencies
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/build_support/windows_release_identity.ps1"
$releaseIdentity = Get-WindowsReleaseIdentity -ProjectRoot $PSScriptRoot
if (-not (Test-Path -LiteralPath $Godot) -or -not (Test-Path -LiteralPath $Template)) {
    throw 'Build the patched editor and release template first with ./build_godot_windows.ps1 (or pass -Godot and -Template).'
}
if (-not $SkipDependencies) { & "$PSScriptRoot/build_dependencies.ps1" }
$output = "$PSScriptRoot/bin/windows"
New-Item -ItemType Directory -Force -Path $output | Out-Null
$managedFiles = @(Get-ChildItem -LiteralPath $output -File | Where-Object { $_.Name -match '^(openvt|OpenVT-Delta-for-Windows|OpenVTDelta-.*)\.(exe|pck|console\.exe)$' })
if (Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -in $managedFiles.FullName }) { throw 'A Windows build is running. Close it before exporting.' }
Set-Content -LiteralPath "$PSScriptRoot/bin/.gdignore" -Value ''
& "$PSScriptRoot/prepare_openseeface.ps1"
& "$PSScriptRoot/prepare_openseeface.ps1" -OutputPath "$output/openseeface"
& "$PSScriptRoot/prepare_windows_notices.ps1" -OutputPath "$output/CorrespondingSource/native-runtime"
Copy-Item -LiteralPath "$PSScriptRoot/thirdparty/godot-vrm/addons/Godot-MToon-Shader/LICENSE" -Destination "$PSScriptRoot/license/LICENSE.mtoon.txt" -Force
Copy-Item -LiteralPath "$PSScriptRoot/thirdparty/ui-icons.json" -Destination "$PSScriptRoot/license/ui-icons-provenance.json" -Force

# Keep the template choice local to this invocation, including custom editor paths.
$presetsPath = Join-Path $PSScriptRoot 'export_presets.cfg'
$originalPresets = [IO.File]::ReadAllText($presetsPath)
try {
    $templatePath = [IO.Path]::GetFullPath($Template).Replace('\', '/')
    $templateSetting = "custom_template/release=`"$templatePath`""
    $templatePattern = [regex]'(?m)^custom_template/release=""'
    $presets = $templatePattern.Replace($originalPresets, [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $templateSetting }, 1)
    [IO.File]::WriteAllText($presetsPath, $presets)
    # A fresh checkout needs a discovery pass before themes and GDExtensions can load.
    if (-not (Test-Path "$PSScriptRoot/.godot/global_script_class_cache.cfg")) {
        & $Godot --headless --path $PSScriptRoot --editor --import --log-file "$PSScriptRoot/bin/windows-bootstrap.log" *> "$PSScriptRoot/bin/windows-bootstrap-output.log"
        if ($LASTEXITCODE -ne 0) { throw 'Godot initial resource discovery failed; see bin/windows-bootstrap-output.log.' }
    }
    $importLog = "$PSScriptRoot/bin/windows-import.log"
    & $Godot --headless --path $PSScriptRoot --editor --import --log-file $importLog
    if ($LASTEXITCODE -ne 0 -or (Select-String -LiteralPath $importLog -Pattern 'SCRIPT ERROR:|ERROR:' -Quiet)) { throw 'Godot project import failed; see bin/windows-import.log.' }
    $engineNoticesLog = "$PSScriptRoot/bin/windows-engine-notices.log"
    $engineNoticesProject = "$PSScriptRoot/bin/engine-notice-project"
    New-Item -ItemType Directory -Force -Path $engineNoticesProject | Out-Null
    Set-Content -LiteralPath "$engineNoticesProject/project.godot" -Value 'config_version=5'
    & $Godot --headless --path $engineNoticesProject --script "$PSScriptRoot/build_support/export_engine_notices.gd" --log-file $engineNoticesLog -- "--output=$PSScriptRoot/license"
    if ($LASTEXITCODE -ne 0 -or (Select-String -LiteralPath $engineNoticesLog -Pattern 'SCRIPT ERROR:|ERROR:' -Quiet)) { throw 'Godot engine license extraction failed; see bin/windows-engine-notices.log.' }
    $exportLog = "$PSScriptRoot/bin/windows-export.log"
    & $Godot --headless --path $PSScriptRoot --export-release windows "$output/$($releaseIdentity.executable)" --log-file $exportLog
    if ($LASTEXITCODE -ne 0 -or (Select-String -LiteralPath $exportLog -Pattern 'SCRIPT ERROR:|ERROR:' -Quiet)) { throw 'Windows export failed; see bin/windows-export.log.' }
} finally {
    [IO.File]::WriteAllText($presetsPath, $originalPresets)
}
foreach ($directory in @('branding', 'license')) {
    New-Item -ItemType Directory -Force -Path "$output/$directory" | Out-Null
    Get-ChildItem "$PSScriptRoot/$directory" -File -Recurse | Where-Object {
        $_.Extension -ne '.import' -and ($directory -ne 'branding' -or $_.Name -in @('delta-icon.svg','delta-splash.svg','delta-splash.png','godot_logo_large_monochrome_dark.svg'))
    } | ForEach-Object {
        $relative = $_.FullName.Substring((Join-Path $PSScriptRoot $directory).Length + 1)
        $destination = Join-Path "$output/$directory" $relative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
    }
}
Copy-Item -LiteralPath "$PSScriptRoot/LICENSE.txt", "$PSScriptRoot/README.md", "$PSScriptRoot/DISTRIBUTION.md", "$PSScriptRoot/CHANGELOG.md" -Destination $output -Force
# Remove only obsolete executables from this build output, after checking they are closed.
$obsoleteFiles = @($managedFiles | Where-Object { $_.Name -notin @($releaseIdentity.executable, $releaseIdentity.pack) } | ForEach-Object FullName)
$obsoleteProcesses = Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -in $obsoleteFiles }
if ($obsoleteProcesses) { throw 'The previous Windows build is running. Close it before replacing the output.' }
foreach ($obsoleteFile in $obsoleteFiles) {
    if (Test-Path -LiteralPath $obsoleteFile) { Remove-Item -LiteralPath $obsoleteFile -Force }
}
foreach ($retiredBranding in @('branding/splash.png','branding/icon.svg','branding/monochrome.svg')) {
    $retiredPath = Join-Path $output $retiredBranding
    if (Test-Path -LiteralPath $retiredPath) { Remove-Item -LiteralPath $retiredPath -Force }
}
$releaseIdentity | ConvertTo-Json | Set-Content -LiteralPath "$output/release.json" -Encoding utf8
Write-Host "OpenVT Delta for Windows build ready: $output/$($releaseIdentity.executable). Distribute the entire windows folder together."
