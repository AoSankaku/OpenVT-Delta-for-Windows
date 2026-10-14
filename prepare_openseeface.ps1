[CmdletBinding()]
param(
    [string]$OutputPath = "$PSScriptRoot/bin/openseeface"
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$manifest = Get-Content -LiteralPath "$projectRoot/thirdparty/openseeface.json" -Raw | ConvertFrom-Json
$downloads = "$projectRoot/bin/downloads"
New-Item -ItemType Directory -Force -Path $downloads | Out-Null
Set-Content -LiteralPath "$projectRoot/bin/.gdignore" -Value ''

function Get-VerifiedArchive {
    param([string]$Url, [string]$Name, [string]$Sha256)
    $destination = Join-Path $downloads $Name
    # Reuse downloads prepared during local investigation, after verification.
    $localArchive = Join-Path "$projectRoot/bin" $Name
    if (-not (Test-Path -LiteralPath $destination) -and (Test-Path -LiteralPath $localArchive)) {
        Copy-Item -LiteralPath $localArchive -Destination $destination
    }
    if (-not (Test-Path -LiteralPath $destination)) {
        Invoke-WebRequest -Uri $Url -OutFile $destination
    }
    $actual = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256) { throw "Checksum mismatch for $Name. Remove the invalid cached archive and try again." }
    return $destination
}

$archive = Get-VerifiedArchive $manifest.archive_url $manifest.archive_name $manifest.sha256
$librarySource = Get-VerifiedArchive $manifest.dshowcapture.source_url $manifest.dshowcapture.source_archive $manifest.dshowcapture.source_sha256
$eigenSource = Get-VerifiedArchive $manifest.eigen.source_url $manifest.eigen.source_archive $manifest.eigen.source_sha256
$source = "$projectRoot/bin/dependency-sources/openseeface-$($manifest.sha256.Substring(0, 12))"
if (-not (Test-Path -LiteralPath "$source/.extracted")) {
    Expand-Archive -LiteralPath $archive -DestinationPath $source -Force
    Set-Content -LiteralPath "$source/.extracted" -Value $manifest.sha256
}
foreach ($architecture in @('x64', 'x86')) {
    $libraryHash = (Get-FileHash -LiteralPath "$source/Binary/dshowcapture_$architecture.dll" -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $manifest.dshowcapture."${architecture}_sha256"
    if ($libraryHash -ne $expected) { throw 'DShowCapture binaries do not match the corresponding source release.' }
}
foreach ($required in @('Binary/facetracker.exe', 'models/lm_model3_opt.onnx', 'LICENSE', 'Licenses/DShowCapture.txt')) {
    if (-not (Test-Path -LiteralPath "$source/$required")) { throw "Incomplete OpenSeeFace release: $required" }
}

$output = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force -Path $output | Out-Null
Set-Content -LiteralPath "$output/.gdignore" -Value ''
foreach ($directory in @('Binary', 'models', 'Licenses')) {
    New-Item -ItemType Directory -Force -Path "$output/$directory" | Out-Null
    Copy-Item -Path "$source/$directory/*" -Destination "$output/$directory" -Recurse -Force
}
Copy-Item -LiteralPath "$source/LICENSE", "$source/README.md" -Destination $output -Force
New-Item -ItemType Directory -Force -Path "$output/CorrespondingSource", "$output/AdditionalLicenses" | Out-Null
Copy-Item -LiteralPath $librarySource -Destination "$output/CorrespondingSource/$($manifest.dshowcapture.source_archive)" -Force
Copy-Item -LiteralPath $eigenSource -Destination "$output/CorrespondingSource/$($manifest.eigen.source_archive)" -Force

# Do not produce a redistributable bundle without the frozen-runtime notices.
$noticesManifestPath = "$projectRoot/thirdparty/openseeface-notices.json"
if (-not (Test-Path -LiteralPath $noticesManifestPath)) { throw 'OpenSeeFace runtime license notices have not been prepared.' }
$notices = Get-Content -LiteralPath $noticesManifestPath -Raw | ConvertFrom-Json
if ($notices.schema_version -ne 1 -or @($notices.components).Count -eq 0) {
    throw 'Unsupported or empty OpenSeeFace runtime notices manifest.'
}
$noticeFiles = @($notices.components | ForEach-Object { $_.notice_files })
if ($noticeFiles.Count -eq 0) { throw 'No OpenSeeFace runtime license notices were declared.' }
foreach ($notice in $noticeFiles) {
    $noticePath = Join-Path $projectRoot $notice.path
    if (-not (Test-Path -LiteralPath $noticePath)) { throw "Missing runtime notice: $($notice.path)" }
    $hash = (Get-FileHash -LiteralPath $noticePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $notice.sha256) { throw "Runtime notice checksum mismatch: $($notice.path)" }
}
Copy-Item -Path "$projectRoot/license/openseeface/*" -Destination "$output/AdditionalLicenses" -Recurse -Force
Copy-Item -LiteralPath $noticesManifestPath -Destination "$output/AdditionalLicenses/provenance.json" -Force
Copy-Item -LiteralPath "$projectRoot/license/OpenSeeFace-NOTICE.txt" -Destination "$output/NOTICE.txt" -Force
Copy-Item -LiteralPath "$projectRoot/thirdparty/openseeface.json" -Destination "$output/bundle.json" -Force
Write-Host "OpenSeeFace $($manifest.version) bundle ready: $output"
