[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'bin/windows/CorrespondingSource/native-runtime'),
    [switch]$Offline
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$projectRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$resolvedOutputPath = if ([IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $projectRoot $OutputPath }
$outputDirectory = [IO.Path]::GetFullPath($resolvedOutputPath)
$packageNoticesRoot = Join-Path $projectRoot 'license/native-runtime'
$manifestPaths = @(
    (Join-Path $projectRoot 'thirdparty/windows-runtime-notices.json'),
    (Join-Path $packageNoticesRoot 'provenance.json')
)
$cacheRoot = Join-Path $projectRoot 'bin/preparecache/windows-runtime-notices'
$cargoHome = if ($env:CARGO_HOME) { [IO.Path]::GetFullPath($env:CARGO_HOME) } else { Join-Path $env:USERPROFILE '.cargo' }
$registryCacheRoot = Join-Path $cargoHome 'registry/cache'
$cargo = (Get-Command cargo -ErrorAction Stop).Source
$git = (Get-Command git -ErrorAction Stop).Source
$target = 'x86_64-pc-windows-msvc'

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function ConvertTo-RelativeManifestPath {
    param([string]$Path)
    return $Path.Replace('\', '/')
}

function Invoke-NativeChecked {
    param([string]$Command, [string[]]$Arguments, [string]$FailureMessage)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$FailureMessage (exit code $LASTEXITCODE)." }
}

function Assert-PathInside {
    param([string]$Path, [string]$ParentPath)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetFullPath($ParentPath).TrimEnd('\') + '\'
    if (-not $fullPath.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify a path outside its generated cache directory: $fullPath"
    }
    return $fullPath
}

function Ensure-VerifiedExternalFile {
    param([string]$Path, [string]$Url, [string]$ExpectedSha256)
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($Offline) { throw "Required upstream license text is missing in offline mode: $Path" }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $Url -OutFile $Path -ErrorAction Stop
    }
    $actualHash = Get-Sha256 $Path
    if ($actualHash -ne $ExpectedSha256) { throw "Upstream license text hash mismatch for $Path ($actualHash != $ExpectedSha256)." }
    return $actualHash
}

function Get-CargoMetadata {
    param([string]$ManifestPath, [string]$Label)
    $stderrPath = Join-Path $cacheRoot "$Label-metadata.stderr.log"
    $metadataOutput = & $cargo metadata --quiet --locked --offline --format-version 1 --filter-platform $target --manifest-path $ManifestPath 2> $stderrPath
    if ($LASTEXITCODE -ne 0 -and -not $Offline) {
        $fetchError = Join-Path $cacheRoot "$Label-fetch.stderr.log"
        & $cargo fetch --locked --manifest-path $ManifestPath 2> $fetchError | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $detail = if (Test-Path -LiteralPath $fetchError) { (Get-Content -LiteralPath $fetchError -Raw).Trim() } else { '' }
            throw "Cargo could not fetch the locked Git/index metadata for $ManifestPath. $detail"
        }
        $metadataOutput = & $cargo metadata --quiet --locked --offline --format-version 1 --filter-platform $target --manifest-path $ManifestPath 2> $stderrPath
    }
    if ($LASTEXITCODE -ne 0) {
        $detail = if (Test-Path -LiteralPath $stderrPath) { (Get-Content -LiteralPath $stderrPath -Raw).Trim() } else { '' }
        throw "Cargo metadata failed for $ManifestPath. $detail"
    }
    $json = [string]::Join([Environment]::NewLine, [string[]]$metadataOutput)
    try { return ($json | ConvertFrom-Json) }
    catch { throw "Cargo metadata returned invalid JSON for $ManifestPath. $($_.Exception.Message)" }
}

function Get-LockPackages {
    param([string]$LockPath)
    $content = Get-Content -LiteralPath $LockPath -Raw
    $result = @()
    foreach ($blockMatch in [regex]::Matches($content, '(?ms)^\[\[package\]\]\s*\r?\n(.*?)(?=^\[\[package\]\]|\z)')) {
        $block = $blockMatch.Groups[1].Value
        $fields = @{}
        foreach ($field in @('name', 'version', 'source', 'checksum')) {
            $match = [regex]::Match($block, "(?m)^$field\s*=\s*`"([^`"]*)`"\s*$")
            if ($match.Success) { $fields[$field] = $match.Groups[1].Value }
        }
        if (-not $fields.ContainsKey('name') -or -not $fields.ContainsKey('version')) { continue }
        if ($fields.source -like 'registry+*') {
            if (-not $fields.ContainsKey('checksum')) { throw "Cargo.lock entry $($fields.name) $($fields.version) has no registry checksum." }
            $result += [pscustomobject]@{
                name = $fields.name; version = $fields.version; source = $fields.source
                checksum = $fields.checksum; kind = 'registry'
            }
        } elseif ($fields.source -like 'git+*') {
            $result += [pscustomobject]@{
                name = $fields.name; version = $fields.version; source = $fields.source
                checksum = $null; kind = 'git'
            }
        }
    }
    return $result
}

function Get-RegistryArchive {
    param([string]$Name, [string]$Version, [string]$ExpectedChecksum)
    $fileName = "$Name-$Version.crate"
    $validCached = @()
    if (Test-Path -LiteralPath $registryCacheRoot) {
        foreach ($candidate in Get-ChildItem -LiteralPath $registryCacheRoot -Filter $fileName -File -Recurse -ErrorAction SilentlyContinue) {
            if ((Get-Sha256 $candidate.FullName) -eq $ExpectedChecksum) { $validCached += $candidate.FullName }
        }
    }

    $staged = Join-Path $cacheRoot 'cargo-crates'
    New-Item -ItemType Directory -Force -Path $staged | Out-Null
    $destination = Join-Path $staged "$Name-$Version-$($ExpectedChecksum.Substring(0, 12)).crate"
    if (Test-Path -LiteralPath $destination) {
        if ((Get-Sha256 $destination) -eq $ExpectedChecksum) { return $destination }
        Remove-Item -LiteralPath $destination -Force
    }

    if ($validCached.Count -gt 0) {
        Copy-Item -LiteralPath $validCached[0] -Destination $destination
    } elseif ($Offline) {
        throw "Verified cache entry missing for $Name $Version ($ExpectedChecksum); -Offline prevents downloading."
    } else {
        $uri = "https://static.crates.io/crates/$Name/$fileName"
        $download = Join-Path $staged "$fileName.download"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $uri -OutFile $download -ErrorAction Stop
            $downloadHash = Get-Sha256 $download
            if ($downloadHash -ne $ExpectedChecksum) {
                throw "Downloaded $Name $Version has SHA-256 $downloadHash, expected $ExpectedChecksum."
            }
            Move-Item -LiteralPath $download -Destination $destination -Force
        } catch {
            Remove-Item -LiteralPath $download -Force -ErrorAction SilentlyContinue
            throw "Could not obtain verified official crates.io archive for $Name $Version. $($_.Exception.Message)"
        }
    }

    $actualHash = Get-Sha256 $destination
    if ($actualHash -ne $ExpectedChecksum) { throw "SHA-256 verification failed for $Name $Version ($actualHash != $ExpectedChecksum)." }
    return $destination
}

function Copy-LegalFiles {
    param([string]$Root, [string]$DestinationRoot, [string]$Component)
    $copied = @()
    if (-not (Test-Path -LiteralPath $Root)) { return $copied }
    foreach ($file in Get-ChildItem -LiteralPath $Root -Recurse -File -Force) {
        $relative = $file.FullName.Substring($Root.TrimEnd('\').Length + 1)
        $normalized = $relative.Replace('\', '/')
        $leaf = [IO.Path]::GetFileName($relative)
        $isLegalDocument = $leaf -match '^(?i)(LICENSE|LICENCE|COPYING|NOTICE|COPYRIGHT)(?:$|[._ -])' -or $normalized -match '^(?i)LICENSES/'
        if (-not $isLegalDocument) { continue }
        $destination = Join-Path $DestinationRoot (Join-Path $Component $relative)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        $copied += ConvertTo-RelativeManifestPath (Join-Path 'license/native-runtime' (Join-Path $Component $relative))
    }
    return $copied | Sort-Object -Unique
}

function New-SourceZipFromDirectory {
    param([string]$SourceDirectory, [string]$ArchivePath, [string[]]$ExcludedRelativePaths = @())
    Add-Type -AssemblyName System.IO.Compression
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ArchivePath) | Out-Null
    if (Test-Path -LiteralPath $ArchivePath) { Remove-Item -LiteralPath $ArchivePath -Force }
    $archive = [IO.Compression.ZipFile]::Open($ArchivePath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $root = [IO.Path]::GetFullPath($SourceDirectory).TrimEnd('\')
        foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName) {
            $relative = $file.FullName.Substring($root.Length + 1)
            $parts = $relative -split '[\\/]'
            if ($parts -contains '.git' -or $parts -contains 'target' -or $parts -contains '.prepared') { continue }
            if ($ExcludedRelativePaths -contains $relative.Replace('\', '/')) { continue }
            $entry = $archive.CreateEntry($relative.Replace('\', '/'), [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $inputStream = [IO.File]::OpenRead($file.FullName)
            $outputStream = $entry.Open()
            try { $inputStream.CopyTo($outputStream) }
            finally { $outputStream.Dispose(); $inputStream.Dispose() }
        }
    } finally { $archive.Dispose() }
}

function Copy-MplSourceHeader {
    param([string]$CrateRoot, [string]$Component)
    foreach ($sourceFile in Get-ChildItem -LiteralPath $CrateRoot -Recurse -File | Where-Object { $_.Extension -in @('.rs', '.c', '.h', '.cpp', '.hpp') } | Sort-Object FullName) {
        $prefix = [string]::Join("`n", [string[]](Get-Content -LiteralPath $sourceFile.FullName -TotalCount 40))
        if ($prefix -notmatch 'Mozilla Public[\s*]+License|MPL-2\.0') { continue }
        $header = [regex]::Match($prefix, '(?s)/\*.*?Copyright.*?Mozilla Public[\s*]+License,\s*v\.\s*2\.0\..*?\*/')
        if (-not $header.Success) { continue }
        $relativeSource = ConvertTo-RelativeManifestPath ($sourceFile.FullName.Substring($CrateRoot.TrimEnd('\').Length + 1))
        $noticeName = ($relativeSource -replace '[^A-Za-z0-9._-]', '_') + '.txt'
        $noticeRelative = "$Component/source-notices/$noticeName"
        $noticePath = Join-Path $packageNoticesRoot $noticeRelative
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $noticePath) | Out-Null
        [IO.File]::WriteAllText($noticePath, $header.Value + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{
            noticePath = ConvertTo-RelativeManifestPath (Join-Path 'license/native-runtime' $noticeRelative)
            sourceFile = $relativeSource
            sourceFileSha256 = Get-Sha256 $sourceFile.FullName
        }
    }
    return $null
}

New-Item -ItemType Directory -Force -Path $cacheRoot, $packageNoticesRoot, $outputDirectory | Out-Null
$registryOutput = Join-Path $outputDirectory 'cargo-crates'
New-Item -ItemType Directory -Force -Path $registryOutput | Out-Null

$keyloggerModule = Join-Path $projectRoot 'thirdparty/godot-keylogger'
$keyloggerRevision = (& $git -C $keyloggerModule rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the pinned keylogger revision.' }
$keyloggerPatch = Join-Path $projectRoot 'patches/keylogger-windows.patch'
$patchHash = (Get-Sha256 $keyloggerPatch).Substring(0, 12).ToUpperInvariant()
$keyloggerSource = Join-Path $projectRoot "bin/dependency-sources/keylogger-$keyloggerRevision-$patchHash"
if (-not (Test-Path -LiteralPath (Join-Path $keyloggerSource '.prepared'))) {
    $dependencySourceRoot = Join-Path $projectRoot 'bin/dependency-sources'
    if (Test-Path -LiteralPath $keyloggerSource) {
        $safeSourcePath = Assert-PathInside -Path $keyloggerSource -ParentPath $dependencySourceRoot
        Remove-Item -LiteralPath $safeSourcePath -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $keyloggerSource | Out-Null
    $keyloggerTar = Join-Path $cacheRoot "keylogger-$keyloggerRevision.tar"
    Invoke-NativeChecked -Command $git -Arguments @('-C', $keyloggerModule, 'archive', '--format=tar', '-o', $keyloggerTar, 'HEAD') -FailureMessage 'Could not archive pinned keylogger source'
    Invoke-NativeChecked -Command (Get-Command tar -ErrorAction Stop).Source -Arguments @('-xf', $keyloggerTar, '-C', $keyloggerSource) -FailureMessage 'Could not extract pinned keylogger source'
    $sourceRelativePath = $keyloggerSource.Substring($projectRoot.Length + 1).Replace('\', '/')
    Invoke-NativeChecked -Command $git -Arguments @('-C', $projectRoot, 'apply', "--directory=$sourceRelativePath", '--check', $keyloggerPatch) -FailureMessage 'The Windows keylogger patch does not apply cleanly'
    Invoke-NativeChecked -Command $git -Arguments @('-C', $projectRoot, 'apply', "--directory=$sourceRelativePath", $keyloggerPatch) -FailureMessage 'Could not apply the Windows keylogger patch'
    Set-Content -LiteralPath (Join-Path $keyloggerSource '.prepared') -Value $keyloggerRevision
}
$preparedRevision = (Get-Content -LiteralPath (Join-Path $keyloggerSource '.prepared') -Raw).Trim()
if ($preparedRevision -ne $keyloggerRevision) {
    throw "The prepared keylogger source does not match the pinned revision ($preparedRevision != $keyloggerRevision)."
}

$components = @(
    @{ label = 'ayagami-gd'; manifest = Join-Path $projectRoot 'thirdparty/ayagami/Cargo.toml'; lock = Join-Path $projectRoot 'thirdparty/ayagami/Cargo.lock' },
    @{ label = 'gd-keylogger'; manifest = Join-Path $keyloggerSource 'Cargo.toml'; lock = Join-Path $projectRoot 'thirdparty/godot-keylogger/Cargo.lock'; buildLock = Join-Path $keyloggerSource 'Cargo.lock' }
)
$metadataByComponent = @{}
$lockedPackages = @()
$lockRecords = @()
foreach ($component in $components) {
    if (-not (Test-Path -LiteralPath $component.lock)) { throw "Expected Cargo.lock not found: $($component.lock)" }
    if ($component.buildLock -and (Get-Sha256 $component.lock) -ne (Get-Sha256 $component.buildLock)) {
        throw 'The patched keylogger Cargo.lock differs from the tracked locked dependency set.'
    }
    $metadata = Get-CargoMetadata -ManifestPath $component.manifest -Label $component.label
    $metadataByComponent[$component.label] = $metadata
    $packageMap = @{}
    foreach ($package in $metadata.packages) { $packageMap["$($package.name)@$($package.version)"] = $package }
    foreach ($locked in Get-LockPackages -LockPath $component.lock) {
        $packageInfo = $packageMap["$($locked.name)@$($locked.version)"]
        $licenseExpression = if ($null -ne $packageInfo) { $packageInfo.license } else { $null }
        if ($locked.kind -eq 'registry') {
            $lockedPackages += [pscustomobject]@{
                name = $locked.name; version = $locked.version; source = $locked.source
                checksum = $locked.checksum; license = $licenseExpression
            }
        } elseif ($locked.kind -eq 'git' -and $packageInfo) {
            $lockedPackages += [pscustomobject]@{
                name = $locked.name; version = $locked.version; source = $locked.source
                checksum = $null; license = $licenseExpression
                manifestPath = $packageInfo.manifest_path
            }
        }
    }
    $lockRecords += [pscustomobject]@{
        component = $component.label
        path = ConvertTo-RelativeManifestPath ($component.lock.Substring($projectRoot.Length + 1))
        sha256 = Get-Sha256 $component.lock
    }
}

# Merge entries appearing in both locks and reject inconsistent registry provenance.
$uniquePackages = @{}
foreach ($package in $lockedPackages) {
    $key = "$($package.name)@$($package.version)"
    if ($uniquePackages.ContainsKey($key)) {
        if ($uniquePackages[$key].checksum -ne $package.checksum -or $uniquePackages[$key].source -ne $package.source) {
            throw "Conflicting locked source/checksum for $key across Windows dependencies."
        }
        continue
    }
    $uniquePackages[$key] = $package
}

$packageRecords = @()
$missingNotices = @()
$supplementalLicenseSources = @()
foreach ($package in ($uniquePackages.Values | Sort-Object name, version)) {
    $componentPath = "crates/$($package.name)-$($package.version)"
    $licensePaths = @()
    if ($package.checksum) {
        $archive = Get-RegistryArchive -Name $package.name -Version $package.version -ExpectedChecksum $package.checksum
        $archivePath = Join-Path $registryOutput (Split-Path -Leaf $archive)
        Copy-Item -LiteralPath $archive -Destination $archivePath -Force
        $archiveHash = Get-Sha256 $archivePath
        $extractPath = Join-Path $cacheRoot "extract-$($package.name)-$($package.version)-$($package.checksum.Substring(0, 12))"
        $extractPath = Assert-PathInside -Path $extractPath -ParentPath $cacheRoot
        if (Test-Path -LiteralPath $extractPath) { Remove-Item -LiteralPath $extractPath -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $extractPath | Out-Null
        Invoke-NativeChecked -Command (Get-Command tar -ErrorAction Stop).Source -Arguments @('-xf', $archivePath, '-C', $extractPath) -FailureMessage "Could not extract $($package.name) $($package.version)"
        $crateRoot = Join-Path $extractPath "$($package.name)-$($package.version)"
        if (-not (Test-Path -LiteralPath $crateRoot)) { throw "Unexpected crate archive layout for $($package.name) $($package.version)." }
        $licenseExpression = $package.license
        if (-not $licenseExpression) {
            $crateManifest = Join-Path $crateRoot 'Cargo.toml'
            if (Test-Path -LiteralPath $crateManifest) {
                $manifestText = Get-Content -LiteralPath $crateManifest -Raw
                $packageSection = [regex]::Match($manifestText, '(?ms)^\[package\]\s*(.*?)(?=^\[|\z)')
                if ($packageSection.Success) {
                    $licenseMatch = [regex]::Match($packageSection.Groups[1].Value, '(?m)^license\s*=\s*"([^"]+)"\s*$')
                    if ($licenseMatch.Success) { $licenseExpression = $licenseMatch.Groups[1].Value }
                }
            }
        }
        $licensePaths = @(Copy-LegalFiles -Root $crateRoot -DestinationRoot $packageNoticesRoot -Component $componentPath)
        $sourceNoticeSources = @()
        if ($licenseExpression -match 'MPL-2\.0' -and $licensePaths.Count -eq 0) {
            $sourceNotice = Copy-MplSourceHeader -CrateRoot $crateRoot -Component $componentPath
            if ($sourceNotice) {
                $licensePaths += $sourceNotice.noticePath
                $sourceNoticeSources += $sourceNotice
            }
        }

        $supplementalFiles = @()
        if ($package.name -eq 'defmt-parser' -and $package.version -eq '1.0.0') {
            $vcsInfoPath = Join-Path $crateRoot '.cargo_vcs_info.json'
            $vcsInfo = Get-Content -LiteralPath $vcsInfoPath -Raw | ConvertFrom-Json
            if ($vcsInfo.git.sha1 -ne '4a8cdb44891ed57b8ff5a023b6bec7137c48708f') { throw 'defmt-parser 1.0.0 source revision differs from its expected upstream license provenance.' }
            foreach ($licenseFile in @('LICENSE-MIT', 'LICENSE-APACHE')) {
                $sourceLicense = Join-Path $packageNoticesRoot "supplemental/defmt-parser-1.0.0/$licenseFile"
                $destinationLicense = Join-Path $packageNoticesRoot (Join-Path $componentPath $licenseFile)
                $expectedHash = if ($licenseFile -eq 'LICENSE-MIT') { '2710a622a896bba67356913d4d0492cab5465f61b2ecce6d880aeb483834fb50' } else { '8173d5c29b4f956d532781d2b86e4e30f83e6b7878dce18c919451d6ba707c90' }
                $url = "https://raw.githubusercontent.com/knurling-rs/defmt/4a8cdb44891ed57b8ff5a023b6bec7137c48708f/$licenseFile"
                $sourceHash = Ensure-VerifiedExternalFile -Path $sourceLicense -Url $url -ExpectedSha256 $expectedHash
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationLicense) | Out-Null
                Copy-Item -LiteralPath $sourceLicense -Destination $destinationLicense -Force
                $supplementalFiles += ConvertTo-RelativeManifestPath (Join-Path 'license/native-runtime' (Join-Path $componentPath $licenseFile))
                $supplementalLicenseSources += [pscustomobject]@{ name = 'defmt-parser'; version = '1.0.0'; upstream = $url; gitRevision = '4a8cdb44891ed57b8ff5a023b6bec7137c48708f'; sha256 = $sourceHash; path = $supplementalFiles[-1] }
            }
            $licensePaths += $supplementalFiles
        } elseif ($package.name -eq 'nanoserde-derive' -and $package.version -eq '0.2.1') {
            $vcsInfoPath = Join-Path $crateRoot '.cargo_vcs_info.json'
            $vcsInfo = Get-Content -LiteralPath $vcsInfoPath -Raw | ConvertFrom-Json
            if ($vcsInfo.git.sha1 -ne '85623c43b0876c23797c6046c8dea18dafa4e7ae') { throw 'nanoserde-derive 0.2.1 source revision differs from its expected upstream license provenance.' }
            $licenseFile = 'LICENSE-MIT'
            $sourceLicense = Join-Path $packageNoticesRoot "supplemental/nanoserde-derive-0.2.1/$licenseFile"
            $destinationLicense = Join-Path $packageNoticesRoot (Join-Path $componentPath $licenseFile)
            $url = 'https://raw.githubusercontent.com/not-fl3/nanoserde/85623c43b0876c23797c6046c8dea18dafa4e7ae/LICENSE-MIT'
            $sourceHash = Ensure-VerifiedExternalFile -Path $sourceLicense -Url $url -ExpectedSha256 '7ba57659687d080189c3f520bc032919d62f45270cbb84977560fa7ab6b24eee'
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destinationLicense) | Out-Null
            Copy-Item -LiteralPath $sourceLicense -Destination $destinationLicense -Force
            $supplementalFiles += ConvertTo-RelativeManifestPath (Join-Path 'license/native-runtime' (Join-Path $componentPath $licenseFile))
            $supplementalLicenseSources += [pscustomobject]@{ name = 'nanoserde-derive'; version = '0.2.1'; upstream = $url; gitRevision = '85623c43b0876c23797c6046c8dea18dafa4e7ae'; sha256 = $sourceHash; path = $supplementalFiles[-1] }
            $licensePaths += $supplementalFiles
        }
        if ($licensePaths.Count -eq 0) {
            $missingNotices += [pscustomobject]@{ name = $package.name; version = $package.version; license = $licenseExpression; reason = 'No LICENSE/COPYING/NOTICE/COPYRIGHT text file found in locked crate archive.' }
        }
        $packageRecords += [pscustomobject]@{
            name = $package.name; version = $package.version; license = $licenseExpression
            source = $package.source; cargoLockChecksum = $package.checksum
            sourceArchive = ConvertTo-RelativeManifestPath (Join-Path 'cargo-crates' (Split-Path -Leaf $archivePath))
            sourceArchiveSha256 = $archiveHash; noticeFiles = @($licensePaths)
            sourceNoticeSources = @($sourceNoticeSources)
        }
    } elseif ($package.manifestPath) {
        $manifestDirectory = Split-Path -Parent $package.manifestPath
        $repoRoot = $manifestDirectory
        while ($repoRoot -and -not (Test-Path -LiteralPath (Join-Path $repoRoot '.git'))) {
            $parent = Split-Path -Parent $repoRoot
            if (-not $parent -or $parent -eq $repoRoot) { $repoRoot = $null; break }
            $repoRoot = $parent
        }
        if (-not $repoRoot) { throw "Could not locate source git checkout for $($package.name)." }
        $sourceInfo = [regex]::Match($package.source, '#(?<rev>[0-9a-fA-F]{7,40})$')
        if (-not $sourceInfo.Success) { throw "No pinned Git revision found in lock source for $($package.name)." }
        $revision = $sourceInfo.Groups['rev'].Value
        $safeDirectory = "safe.directory=$($repoRoot.Replace('\', '/'))"
        $resolvedRevision = (& $git -c $safeDirectory -C $repoRoot rev-parse $revision).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $resolvedRevision) { throw "Pinned Git revision $revision is unavailable for $($package.name)." }
        $gitArchiveName = "git-$($package.name)-$($package.version)-$($revision.Substring(0, 8)).zip"
        $gitArchiveCache = Join-Path $cacheRoot 'git-sources'
        New-Item -ItemType Directory -Force -Path $gitArchiveCache | Out-Null
        $gitArchiveStaged = Join-Path $gitArchiveCache $gitArchiveName
        if (Test-Path -LiteralPath $gitArchiveStaged) { Remove-Item -LiteralPath $gitArchiveStaged -Force }
        Invoke-NativeChecked -Command $git -Arguments @('-c', $safeDirectory, '-C', $repoRoot, 'archive', '--format=zip', "--prefix=$($package.name)-$($package.version)/", '-o', $gitArchiveStaged, $resolvedRevision) -FailureMessage "Could not archive locked Git source for $($package.name)"
        $gitArchivePath = Join-Path $outputDirectory $gitArchiveName
        Copy-Item -LiteralPath $gitArchiveStaged -Destination $gitArchivePath -Force
        $licensePaths = @(Copy-LegalFiles -Root $repoRoot -DestinationRoot $packageNoticesRoot -Component "git/$($package.name)-$($package.version)")
        if ($licensePaths.Count -eq 0) {
            $missingNotices += [pscustomobject]@{ name = $package.name; version = $package.version; license = $package.license; reason = 'No LICENSE/COPYING/NOTICE/COPYRIGHT text file found in locked Git source.' }
        }
        $packageRecords += [pscustomobject]@{
            name = $package.name; version = $package.version; license = $package.license
            source = $package.source; cargoLockChecksum = $null
            sourceArchive = ConvertTo-RelativeManifestPath (Split-Path -Leaf $gitArchivePath)
            sourceArchiveSha256 = Get-Sha256 $gitArchivePath; noticeFiles = @($licensePaths)
        }
    }
}

# Retain the exact source of the locally patched Windows keylogger build.
$keyloggerArchiveName = "patched-gd-keylogger-$keyloggerRevision-$patchHash.zip"
$keyloggerArchiveStaged = Join-Path $cacheRoot $keyloggerArchiveName
New-SourceZipFromDirectory -SourceDirectory $keyloggerSource -ArchivePath $keyloggerArchiveStaged
$keyloggerArchive = Join-Path $outputDirectory $keyloggerArchiveName
Copy-Item -LiteralPath $keyloggerArchiveStaged -Destination $keyloggerArchive -Force
$keyloggerSourceRecord = [pscustomobject]@{
    component = 'gd-keylogger (Windows patch)'; version = '0.3.0'
    source = "git+https://github.com/erodozer/godot-keylogger#$keyloggerRevision plus patches/keylogger-windows.patch"
    gitRevision = $keyloggerRevision; patchSha256 = Get-Sha256 $keyloggerPatch
    sourceArchive = $keyloggerArchiveName; sourceArchiveSha256 = Get-Sha256 $keyloggerArchive
    licenseNotice = 'license/LICENSE.keylogger.md'
}

# Copy the Rust standard library's bundled third-party copyright notices used by the statically linked Rust runtime.
$rustc = (Get-Command rustc -ErrorAction Stop).Source
$rustVersionStderr = Join-Path $cacheRoot 'rustc-version.stderr.log'
$rustVersionOutput = & $rustc --version --verbose 2> $rustVersionStderr
if ($LASTEXITCODE -ne 0) { throw 'Could not query the Rust compiler version.' }
$rustVersion = [string]::Join([Environment]::NewLine, [string[]]$rustVersionOutput).Trim()
$rustSysrootStderr = Join-Path $cacheRoot 'rustc-sysroot.stderr.log'
$rustSysrootOutput = & $rustc --print sysroot 2> $rustSysrootStderr
if ($LASTEXITCODE -ne 0) { throw 'Could not locate the Rust compiler sysroot.' }
$rustSysroot = [string]::Join([Environment]::NewLine, [string[]]$rustSysrootOutput).Trim()
$rustNoticesSource = Join-Path $rustSysroot 'share/doc/rust/COPYRIGHT-library.html'
if (-not (Test-Path -LiteralPath $rustNoticesSource)) { throw "Rust standard-library notices not found: $rustNoticesSource" }
$rustNoticesDestination = Join-Path $packageNoticesRoot 'rust/COPYRIGHT-library.html'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $rustNoticesDestination) | Out-Null
Copy-Item -LiteralPath $rustNoticesSource -Destination $rustNoticesDestination -Force
$rustRecord = [pscustomobject]@{
    rustcVersion = $rustVersion
    standardLibraryNoticeSource = 'rustup toolchain share/doc/rust/COPYRIGHT-library.html'
    standardLibraryNotice = 'license/native-runtime/rust/COPYRIGHT-library.html'
    standardLibraryNoticeSourceSha256 = Get-Sha256 $rustNoticesSource
    standardLibraryNoticeSha256 = Get-Sha256 $rustNoticesDestination
}

$mplLicensePath = Join-Path $packageNoticesRoot 'MPL-2.0.txt'
$mplLicenseUrl = 'https://www.mozilla.org/media/MPL/2.0/index.f75d2927d3c1.txt'
$mplLicenseHash = Ensure-VerifiedExternalFile -Path $mplLicensePath -Url $mplLicenseUrl -ExpectedSha256 '3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04'
$mplLicenseRecord = [pscustomobject]@{
    spdx = 'MPL-2.0'; path = 'license/native-runtime/MPL-2.0.txt'
    upstream = $mplLicenseUrl; sha256 = $mplLicenseHash
    appliesTo = @($packageRecords | Where-Object { $_.license -match 'MPL-2\.0' } | ForEach-Object { "$($_.name)@$($_.version)" } | Sort-Object -Unique)
    sourceArchiveCoverage = 'Each locked godot-rust/MPL-2.0 crate is shipped as its SHA-256-verified original .crate archive under CorrespondingSource/native-runtime/cargo-crates; those archives preserve the exact covered source and per-file license headers.'
}

$manifest = [ordered]@{
    schemaVersion = 1
    target = $target
    acquisition = 'Every registry archive is verified against the SHA-256 in Cargo.lock. Cached .crate files are preferred; missing files are fetched from static.crates.io and verified before use.'
    lockFiles = @($lockRecords)
    packages = @($packageRecords)
    additionalSources = @($keyloggerSourceRecord)
    rustStandardLibrary = $rustRecord
    supplementalLicenseSources = @($supplementalLicenseSources)
    standaloneLicenseTexts = @($mplLicenseRecord)
    missingNoticeFiles = @($missingNotices)
}
$manifestJson = ConvertTo-Json -InputObject $manifest -Depth 30
$utf8NoBom = [Text.UTF8Encoding]::new($false)
foreach ($manifestPath in $manifestPaths) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $manifestPath) | Out-Null
    [IO.File]::WriteAllText($manifestPath, $manifestJson + [Environment]::NewLine, $utf8NoBom)
}

$noticesOutput = Join-Path $outputDirectory 'notices'
New-Item -ItemType Directory -Force -Path $noticesOutput | Out-Null
foreach ($notice in Get-ChildItem -LiteralPath $packageNoticesRoot -Recurse -File -Force) {
    $relative = $notice.FullName.Substring($packageNoticesRoot.TrimEnd('\').Length + 1)
    $destination = Join-Path $noticesOutput $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $notice.FullName -Destination $destination -Force
}

Write-Host "Prepared $($packageRecords.Count) locked Cargo package sources and $($missingNotices.Count) packages without standalone legal-text files."
Write-Host "Corresponding source: $outputDirectory"
Write-Host "Notices and provenance: $packageNoticesRoot"
if ($missingNotices.Count -gt 0) {
    $missingSummary = ($missingNotices | ForEach-Object { "$($_.name)@$($_.version)" }) -join ', '
    throw "Windows native runtime notices are incomplete: $missingSummary. Resolve every missingNoticeFiles entry before packaging."
}
