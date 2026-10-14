[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$target = 'x86_64-pc-windows-msvc'

function Split-RustFlags {
    param([string]$Value)

    $tokens = [Collections.Generic.List[string]]::new()
    $token = [Text.StringBuilder]::new()
    $quote = [char]0
    $started = $false
    for ($index = 0; $index -lt $Value.Length; $index++) {
        $character = $Value[$index]
        if ($character -eq '\' -and $quote -ne "'") {
            if ($index + 1 -lt $Value.Length) {
                $next = $Value[$index + 1]
                if ($next -eq '\' -or $next -eq '"' -or $next -eq "'" -or [char]::IsWhiteSpace($next)) {
                    [void]$token.Append($next)
                    $started = $true
                    $index++
                    continue
                }
            }
            [void]$token.Append($character)
            $started = $true
            continue
        }
        if (($character -eq '"' -or $character -eq "'") -and ($quote -eq [char]0 -or $quote -eq $character)) {
            $quote = if ($quote -eq [char]0) { $character } else { [char]0 }
            $started = $true
            continue
        }
        if ([char]::IsWhiteSpace($character) -and $quote -eq [char]0) {
            if ($started) {
                $tokens.Add($token.ToString())
                [void]$token.Clear()
                $started = $false
            }
            continue
        }
        [void]$token.Append($character)
        $started = $true
    }
    if ($quote -ne [char]0) { throw 'RUSTFLAGS contains an unmatched quote; cannot preserve the existing flags safely.' }
    if ($started) { $tokens.Add($token.ToString()) }
    return $tokens.ToArray()
}

function Get-PathRemapFlags {
    $profile = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($profile)) { $profile = [Environment]::GetFolderPath('UserProfile') }
    $cargoHome = $env:CARGO_HOME
    if ([string]::IsNullOrWhiteSpace($cargoHome)) { $cargoHome = Join-Path $profile '.cargo' }

    $mappings = @(
        @{ Path = $projectRoot; Alias = '/__openvt__/project' },
        @{ Path = $cargoHome; Alias = '/__openvt__/cargo' },
        @{ Path = $profile; Alias = '/__openvt__/user' }
    ) | Sort-Object { ([IO.Path]::GetFullPath($_.Path)).Length } -Descending

    $flags = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($mapping in $mappings) {
        $path = [IO.Path]::GetFullPath($mapping.Path).TrimEnd('\', '/')
        foreach ($variant in @($path, $path.Replace('\', '/'))) {
            if ($seen.Add($variant)) {
                $flags.Add("--remap-path-prefix=$variant=$($mapping.Alias)")
            }
        }
    }
    return $flags.ToArray()
}

function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed with exit code $LASTEXITCODE" }
}

foreach ($command in @('cargo', 'git', 'tar')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Install $command and make it available on PATH before building dependencies."
    }
}
foreach ($module in @('ayagami', 'godot-keylogger', 'godot-vrm')) {
    if (-not (Test-Path "$projectRoot/thirdparty/$module/.git")) {
        throw 'Initialize dependencies first: git submodule update --init --recursive'
    }
}

$addons = Join-Path $projectRoot 'addons'
New-Item -ItemType Directory -Force -Path $addons, "$projectRoot/license", "$projectRoot/bin" | Out-Null
Set-Content -LiteralPath "$projectRoot/bin/.gdignore" -Value ''

function Copy-Addon {
    param([string]$Source, [string]$Name)
    $destination = Join-Path $addons $Name
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    Copy-Item -Path "$Source/*" -Destination $destination -Recurse -Force
    Set-Content -LiteralPath "$destination/.gitignore" -Value '*' -Encoding utf8
}

# Build a patched copy so the checked-out submodule stays at its pinned revision.
$keyloggerModule = Join-Path $projectRoot 'thirdparty/godot-keylogger'
$patch = Join-Path $projectRoot 'patches/keylogger-windows.patch'
$revision = (& git -C $keyloggerModule rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the keylogger revision.' }
$patchHash = (Get-FileHash -LiteralPath $patch -Algorithm SHA256).Hash.Substring(0, 12)
$keyloggerSource = Join-Path $projectRoot "bin/dependency-sources/keylogger-$revision-$patchHash"
if (-not (Test-Path "$keyloggerSource/.prepared")) {
    New-Item -ItemType Directory -Force -Path $keyloggerSource | Out-Null
    $archive = Join-Path $projectRoot 'bin/keylogger-source.tar'
    Invoke-Checked git @('-C', $keyloggerModule, 'archive', '--format=tar', '-o', $archive, 'HEAD')
    Invoke-Checked tar @('-xf', $archive, '-C', $keyloggerSource)
    $sourceRelative = $keyloggerSource.Substring($projectRoot.Length + 1).Replace('\', '/')
    Invoke-Checked git @('-C', $projectRoot, 'apply', "--directory=$sourceRelative", '--check', $patch)
    Invoke-Checked git @('-C', $projectRoot, 'apply', "--directory=$sourceRelative", $patch)
    Set-Content -LiteralPath "$keyloggerSource/.prepared" -Value $revision
}

foreach ($dependency in @(
    @{ Source = "$projectRoot/thirdparty/ayagami"; Addon = 'ayagami'; Library = 'ayagami_gd' },
    @{ Source = $keyloggerSource; Addon = 'keylogger'; Library = 'gd_keylogger' }
)) {
    Write-Host "Building $($dependency.Addon) for Windows x64..."
    $cargoTarget = "$($dependency.Source)/target"
    if ($dependency.Addon -eq 'keylogger') { $cargoTarget = "$projectRoot/bin/keylogger-target" }
    if ($env:CARGO_TARGET_DIR) { $cargoTarget = [IO.Path]::GetFullPath($env:CARGO_TARGET_DIR) }
    # Remap source locations in every crate so debug/panic metadata cannot disclose
    # the build machine. Cargo fingerprints these rustc flags and rebuilds stale artifacts.
    $previousRustFlags = $env:RUSTFLAGS
    $previousEncodedRustFlags = $env:CARGO_ENCODED_RUSTFLAGS
    $hadRustFlags = Test-Path Env:RUSTFLAGS
    $hadEncodedRustFlags = Test-Path Env:CARGO_ENCODED_RUSTFLAGS
    try {
        $rustFlags = [Collections.Generic.List[string]]::new()
        if ($hadEncodedRustFlags -and -not [string]::IsNullOrEmpty($previousEncodedRustFlags)) {
            foreach ($flag in $previousEncodedRustFlags.Split([char]31, [StringSplitOptions]::RemoveEmptyEntries)) { $rustFlags.Add($flag) }
        } elseif ($hadRustFlags -and -not [string]::IsNullOrWhiteSpace($previousRustFlags)) {
            foreach ($flag in (Split-RustFlags $previousRustFlags)) { $rustFlags.Add($flag) }
        }
        foreach ($flag in (Get-PathRemapFlags)) { $rustFlags.Add($flag) }
        $env:CARGO_ENCODED_RUSTFLAGS = $rustFlags -join [char]31
        Remove-Item Env:RUSTFLAGS -ErrorAction SilentlyContinue

        # Keep the MSVC runtime linked into each DLL for clean Windows installations.
        Invoke-Checked cargo @('rustc', '--locked', '--release', '--lib', '--target', $target, '--target-dir', $cargoTarget, '--manifest-path', "$($dependency.Source)/Cargo.toml", '--', '-C', 'target-feature=+crt-static')
    } finally {
        if ($hadRustFlags) { $env:RUSTFLAGS = $previousRustFlags } else { Remove-Item Env:RUSTFLAGS -ErrorAction SilentlyContinue }
        if ($hadEncodedRustFlags) { $env:CARGO_ENCODED_RUSTFLAGS = $previousEncodedRustFlags } else { Remove-Item Env:CARGO_ENCODED_RUSTFLAGS -ErrorAction SilentlyContinue }
    }
    Copy-Addon "$($dependency.Source)/addons/$($dependency.Addon)" $dependency.Addon
    $libraryDir = Join-Path $addons "$($dependency.Addon)/lib"
    New-Item -ItemType Directory -Force -Path $libraryDir | Out-Null
    $cargoOutput = Join-Path $cargoTarget "$target/release/$($dependency.Library).dll"
    $libraryName = "lib$($dependency.Library).release.x86_64.dll"
    Copy-Item -LiteralPath $cargoOutput -Destination "$libraryDir/$libraryName" -Force
    # One optimized DLL serves both editor/debug runs and release exports.
    $descriptor = Get-ChildItem "$addons/$($dependency.Addon)/*.gdextension" | Select-Object -First 1
    $contents = Get-Content -LiteralPath $descriptor.FullName -Raw
    $contents = $contents -replace '(?m)^windows\.(debug|release)\.x86_64\s*=.*$', "windows.`$1.x86_64 = `"res://addons/$($dependency.Addon)/lib/$libraryName`""
    Set-Content -LiteralPath $descriptor.FullName -Value $contents -Encoding utf8
    Copy-Item -LiteralPath "$($dependency.Source)/LICENSE.md" -Destination "$projectRoot/license/LICENSE.$($dependency.Addon).md" -Force
    Copy-Item -LiteralPath "$($dependency.Source)/README.md" -Destination "$addons/$($dependency.Addon)/README.md" -Force
}

Copy-Addon "$projectRoot/thirdparty/godot-vrm/addons/vrm" 'vrm'
Copy-Addon "$projectRoot/thirdparty/godot-vrm/addons/Godot-MToon-Shader" 'Godot-MToon-Shader'
Copy-Item -LiteralPath "$projectRoot/thirdparty/godot-vrm/LICENSE" -Destination "$projectRoot/license/LICENSE.godotvrm.md" -Force
Write-Host 'Windows dependencies are ready. Virtual camera output uses OBS capture on Windows.'
