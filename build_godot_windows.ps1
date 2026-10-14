[CmdletBinding()]
param(
    [string]$Python = 'python',
    [int]$Jobs = [Math]::Max(1, [Math]::Min(8, [Environment]::ProcessorCount)),
    [string]$Source = "$PSScriptRoot/bin/tools/godot-4.7.1-stable",
    [ValidateSet('editor', 'template_release')]
    [string[]]$Targets = @('editor', 'template_release')
)

$ErrorActionPreference = 'Stop'
$version = '4.7.1'
New-Item -ItemType Directory -Force -Path "$PSScriptRoot/bin" | Out-Null
Set-Content -LiteralPath "$PSScriptRoot/bin/.gdignore" -Value ''
$patch = "$PSScriptRoot/thirdparty/ayagami/patches/custom_blend_modes-4_7_1.patch"
if (-not (Test-Path -LiteralPath $patch)) {
    throw 'Initialize dependencies first: git submodule update --init --recursive'
}
if (-not (Test-Path "$Source/SConstruct")) {
    $parent = Split-Path -Parent $Source
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    $archive = Join-Path $parent "godot-$version.zip"
    Invoke-WebRequest "https://github.com/godotengine/godot/archive/refs/tags/$version-stable.zip" -OutFile $archive
    Expand-Archive -LiteralPath $archive -DestinationPath $parent -Force
}

$pythonCommand = Get-Command $Python -ErrorAction SilentlyContinue
$pythonExecutable = $null
$pythonPrefixArguments = @()
if ($pythonCommand) {
    $pythonExecutable = $pythonCommand.Source
    if ([string]::IsNullOrWhiteSpace($pythonExecutable)) { $pythonExecutable = $pythonCommand.Path }
} else {
    $pythonLauncher = Get-Command py -ErrorAction SilentlyContinue
    if (-not $pythonLauncher) { throw 'Python was not found. Install Python or make the Windows py launcher available.' }
    $pythonExecutable = $pythonLauncher.Source
    if ([string]::IsNullOrWhiteSpace($pythonExecutable)) { $pythonExecutable = $pythonLauncher.Path }
    $pythonPrefixArguments = @('-3')
}

$sourcePath = [IO.Path]::GetFullPath($Source)
$buildRoot = [IO.Path]::GetFullPath("$PSScriptRoot/bin") + [IO.Path]::DirectorySeparatorChar
if (-not $sourcePath.StartsWith($buildRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Use a Godot source directory inside this repository bin folder.'
}
$sourceRelative = $sourcePath.Substring($PSScriptRoot.Length + 1).Replace('\', '/')
# Submodule checkouts can have CRLF patches; source archives always use LF.
$normalizedPatch = "$PSScriptRoot/bin/ayagami-engine.patch"
[IO.File]::WriteAllText($normalizedPatch, [IO.File]::ReadAllText($patch).Replace("`r`n", "`n"))
& git -C $PSScriptRoot apply "--directory=$sourceRelative" --reverse --check $normalizedPatch 2>$null
if ($LASTEXITCODE -ne 0) {
    & git -C $PSScriptRoot apply "--directory=$sourceRelative" --check $normalizedPatch
    if ($LASTEXITCODE -ne 0) { throw 'The Ayagami engine patch does not match the Godot source.' }
    & git -C $PSScriptRoot apply "--directory=$sourceRelative" $normalizedPatch
    if ($LASTEXITCODE -ne 0) { throw 'Cannot apply the Ayagami engine patch.' }
}

$repoRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/')
if ($repoRoot -match '\s') {
    throw 'The Godot SCons ccflags parser cannot safely represent spaces in the repository path; move the checkout to a path without spaces before building the release template.'
}
$pathForms = @($repoRoot, $repoRoot.Replace('\', '/')) | Select-Object -Unique
$pathMapArguments = @('/experimental:deterministic') + @($pathForms | ForEach-Object { "/pathmap:$($_)=C:\OpenVT\source" })

# SCons is pinned in the repository cache so a clean machine need not install it globally.
$pythonPackages = Join-Path $PSScriptRoot 'bin/tools/python-packages'
$oldPythonPath = $env:PYTHONPATH
$hadPythonPath = Test-Path Env:PYTHONPATH
try {
    if ($hadPythonPath -and -not [string]::IsNullOrWhiteSpace($oldPythonPath)) {
        $env:PYTHONPATH = "$pythonPackages$([IO.Path]::PathSeparator)$oldPythonPath"
    } else {
        $env:PYTHONPATH = $pythonPackages
    }

    # Vulkan and OpenGL are sufficient; omitting D3D12 avoids additional SDK downloads.
    foreach ($target in $Targets) {
        $arguments = @($pythonPrefixArguments) + @(
            '-m', 'SCons', '-C', $Source, 'platform=windows', "target=$target",
            'arch=x86_64', 'd3d12=no', 'accesskit=no', 'debug_symbols=no',
            'use_static_cpp=yes', "-j$Jobs", "ccflags=$($pathMapArguments -join ' ')"
        )
        & $pythonExecutable @arguments
        if ($LASTEXITCODE -ne 0) { throw "Godot $target build failed." }
    }
} finally {
    if ($hadPythonPath) { $env:PYTHONPATH = $oldPythonPath } else { Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue }
}

$destination = "$PSScriptRoot/bin/godot"
New-Item -ItemType Directory -Force -Path $destination | Out-Null
Set-Content -LiteralPath "$destination/_sc_" -Value ''
if ($Targets -contains 'editor') {
    Copy-Item -Path "$Source/bin/godot.windows.editor.x86_64*.exe" -Destination $destination -Force
}
if ($Targets -contains 'template_release') {
    Copy-Item -LiteralPath "$Source/bin/godot.windows.template_release.x86_64.exe" -Destination "$destination/windows_release_x86_64.exe" -Force
}
Write-Host "Patched Godot $version targets ($($Targets -join ', ')) are in $destination."
