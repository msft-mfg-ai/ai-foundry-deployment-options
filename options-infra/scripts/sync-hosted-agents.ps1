param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]] $Mappings
)

$ErrorActionPreference = 'Stop'

foreach ($mapping in $Mappings) {
    $parts = $mapping.Split('=', 2)
    if ($parts.Count -ne 2) {
        throw "Invalid mapping '$mapping'; expected SOURCE=DESTINATION."
    }

    $sourcePath = $parts[0]
    $destinationPath = $parts[1]
    if ($destinationPath -notmatch '^\.hosted-agent-build[/\\]') {
        throw "Refusing to replace unsafe destination '$destinationPath'."
    }
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) {
        throw "Hosted-agent source directory not found: $sourcePath"
    }

    New-Item -ItemType Directory -Path $destinationPath -Force | Out-Null
    Get-ChildItem -LiteralPath $destinationPath -Force |
        Where-Object { $_.Name -ne '.gitignore' } |
        Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $sourcePath -Force |
        Copy-Item -Destination $destinationPath -Recurse -Force
    $generatedDirectories = Get-ChildItem -LiteralPath $destinationPath -Directory -Recurse -Force |
        Where-Object { $_.Name -in @('.venv', '__pycache__', 'bin', 'obj') } |
        Sort-Object { $_.FullName.Length } -Descending
    $generatedDirectories | Remove-Item -Recurse -Force
    Get-ChildItem -LiteralPath $destinationPath -File -Recurse -Force |
        Where-Object { $_.Extension -in @('.pyc', '.pyo') } |
        Remove-Item -Force
    Write-Host "Staged $sourcePath -> $destinationPath"
}
