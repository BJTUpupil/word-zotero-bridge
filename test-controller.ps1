$ErrorActionPreference = 'Stop'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot 'controller\Invoke-CitationBatch.ps1'),
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    exit 1
}
$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'controller\Invoke-CitationBatch.ps1') -Raw
foreach ($required in @(
    'UseProxy = $false',
    '.word-zotero-bridge\work',
    'ZOTERO_ITEM\s+CSL_CITATION',
    'Target document already exists',
    'sourceDocument must be inside projectRoot'
)) {
    if (-not $source.Contains($required)) {
        throw ('Missing controller safety contract: ' + $required)
    }
}
if ($source -match 'return\s+[,]\$codes\.ToArray\(\)') {
    throw 'Citation snapshots must not be wrapped as a nested array.'
}
Write-Host 'PASS controller syntax and safety-contract checks'
