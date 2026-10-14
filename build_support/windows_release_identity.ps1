function Get-WindowsReleaseIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProjectRoot)

    $projectText = [IO.File]::ReadAllText((Join-Path $ProjectRoot 'project.godot'))
    $nameMatch = [regex]::Match($projectText, '(?m)^config/name="([^"]+)"')
    if (-not $nameMatch.Success) { throw 'The application name is missing from project.godot.' }
    $productName = $nameMatch.Groups[1].Value
    $revision = (& git -C $ProjectRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the release commit.' }
    $shortRevision = (& git -C $ProjectRoot rev-parse --short HEAD).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Cannot resolve the short release commit.' }
    $branch = ([string](& git -C $ProjectRoot branch --show-current)).Trim()
    if (-not $branch) {
        $branch = if ($env:GITHUB_HEAD_REF) { $env:GITHUB_HEAD_REF } elseif ($env:GITHUB_REF_TYPE -eq 'branch' -and $env:GITHUB_REF_NAME) { $env:GITHUB_REF_NAME } else { 'detached' }
    }
    $safeBranch = [regex]::Replace($branch, '[^A-Za-z0-9._-]', '-').Trim('-','.')
    if (-not $safeBranch) { throw 'The release branch has no filename-safe characters.' }
    # Keep the product recognizable while reserving the complete short commit and extension.
    $app = [regex]::Replace(($productName -replace '(?i)\s+for\s+Windows$', ''), '[^A-Za-z0-9]', '')
    $available = 28 - '.exe'.Length - $shortRevision.Length - 2
    if ($available -lt 3) { throw 'The commit identifier is too long for a descriptive 28-character filename.' }
    $appLength = [Math]::Min($app.Length, $available - 1)
    $branchLength = [Math]::Min($safeBranch.Length, $available - $appLength)
    $baseName = $app.Substring(0, $appLength) + '-' + $safeBranch.Substring(0, $branchLength) + '-' + $shortRevision
    return [pscustomobject]@{
        productName = $productName
        branch = $branch
        revision = $revision
        shortRevision = $shortRevision
        architecture = 'x64'
        executable = "$baseName.exe"
        pack = "$baseName.pck"
    }
}
