[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BatchPath,

    [switch]$Apply,

    [string]$Endpoint = 'http://127.0.0.1:23119/word-zotero-bridge/v1/command'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
}

function Test-UnderRoot([string]$Path, [string]$Root) {
    $candidate = Get-FullPath $Path
    $prefix = (Get-FullPath $Root) + [System.IO.Path]::DirectorySeparatorChar
    return $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-Batch($Config) {
    if ([string]::IsNullOrWhiteSpace([string]$Config.id) -or [string]$Config.id -notmatch '^[A-Za-z0-9_-]{1,80}$') {
        throw 'Invalid batch id.'
    }
    if ([string]$Config.collection -ne 'MC8W6IIE') {
        throw 'Only Zotero collection MC8W6IIE is authorized.'
    }
    $projectRoot = Get-FullPath ([string]$Config.projectRoot)
    $source = Get-FullPath ([string]$Config.sourceDocument)
    $target = Get-FullPath ([string]$Config.document)
    if (-not (Test-Path -LiteralPath $projectRoot -PathType Container)) {
        throw 'projectRoot does not exist.'
    }
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or [System.IO.Path]::GetExtension($source) -ine '.docx') {
        throw 'sourceDocument must be an existing DOCX.'
    }
    if (-not (Test-UnderRoot $source $projectRoot)) {
        throw 'sourceDocument must be inside projectRoot.'
    }
    $workRoot = Get-FullPath (Join-Path $projectRoot '.word-zotero-bridge\work')
    $targetParent = Get-FullPath ([System.IO.Path]::GetDirectoryName($target))
    if (-not $targetParent.Equals($workRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'document must be directly under PROJECT\.word-zotero-bridge\work.'
    }
    if ([System.IO.Path]::GetExtension($target) -ine '.docx') {
        throw 'document must use the .docx extension.'
    }
    if ($source.Equals($target, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The source document cannot be the target document.'
    }
    if ($null -eq $Config.jobs -or $Config.jobs.Count -lt 1 -or $Config.jobs.Count -gt 256) {
        throw 'A batch must contain 1-256 jobs.'
    }
    $ids = @{}
    foreach ($job in $Config.jobs) {
        if ([string]$job.id -notmatch '^[A-Za-z0-9_-]{1,80}$' -or [string]$job.id -eq 'final-refresh') {
            throw 'Invalid job id.'
        }
        if ($ids.ContainsKey([string]$job.id)) {
            throw ('Duplicate job id: ' + [string]$job.id)
        }
        $ids[[string]$job.id] = $true
        if ([string]$job.key -notmatch '^[A-Z0-9]{8}$') {
            throw ('Invalid Zotero item key: ' + [string]$job.key)
        }
        if ([string]::IsNullOrWhiteSpace([string]$job.title) -or $null -eq $job.doi) {
            throw ('Incomplete item identity: ' + [string]$job.id)
        }
        if ($null -eq $job.anchor -or [string]::IsNullOrEmpty([string]$job.anchor.text)) {
            throw ('Missing anchor: ' + [string]$job.id)
        }
        if ([string]$job.anchor.position -notin @('before', 'after', 'replace')) {
            throw ('Invalid anchor position: ' + [string]$job.id)
        }
        if ([int]$job.anchor.occurrence -lt 1) {
            throw ('Invalid anchor occurrence: ' + [string]$job.id)
        }
    }
    return @{
        ProjectRoot = $projectRoot
        Source = $source
        Target = $target
        WorkRoot = $workRoot
        JournalRoot = Get-FullPath (Join-Path $projectRoot '.word-zotero-bridge\journal')
    }
}

function New-LocalHttpClient {
    Add-Type -AssemblyName System.Net.Http
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    return $client
}

function Invoke-Bridge($Client, [string]$Uri, $Payload) {
    $json = $Payload | ConvertTo-Json -Depth 20 -Compress
    $content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, 'application/json')
    try {
        $response = $Client.PostAsync($Uri, $content).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw ('Bridge HTTP ' + [int]$response.StatusCode + ': ' + $body)
        }
        $result = $body | ConvertFrom-Json
        if ($result.ok -ne $true) {
            throw ('Bridge rejected the command: ' + [string]$result.error)
        }
        return $result
    }
    finally {
        $content.Dispose()
    }
}

function Select-Anchor($Document, $Anchor) {
    $cursor = $Document.Content.Start
    $foundRange = $null
    for ($index = 1; $index -le [int]$Anchor.occurrence; $index++) {
        $range = $Document.Range($cursor, $Document.Content.End)
        $find = $range.Find
        $find.ClearFormatting()
        $find.Text = [string]$Anchor.text
        $find.Forward = $true
        $find.Wrap = 0
        $find.Format = $false
        $find.MatchCase = $true
        $find.MatchWildcards = $false
        if (-not $find.Execute()) {
            throw ('Anchor occurrence not found: ' + [string]$Anchor.text)
        }
        $foundRange = $range
        $cursor = $range.End
    }
    switch ([string]$Anchor.position) {
        'before' { $foundRange.SetRange($foundRange.Start, $foundRange.Start) }
        'after' { $foundRange.SetRange($foundRange.End, $foundRange.End) }
        'replace' {
            $foundRange.Text = ''
            $foundRange.Collapse(1)
        }
    }
    $foundRange.Select()
    return $foundRange.Start
}

function Get-CitationSnapshot($Document) {
    $codes = [System.Collections.Generic.List[string]]::new()
    for ($index = 1; $index -le $Document.Fields.Count; $index++) {
        $code = [string]$Document.Fields.Item($index).Code.Text
        if ($code -match 'ZOTERO_ITEM\s+CSL_CITATION') {
            $codes.Add($code)
        }
    }
    return $codes.ToArray()
}

function Write-Journal([string]$Path, $Journal) {
    $json = $Journal | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

$batchFile = Get-FullPath $BatchPath
if (-not (Test-Path -LiteralPath $batchFile -PathType Leaf)) {
    throw 'Batch JSON does not exist.'
}
$config = Get-Content -LiteralPath $batchFile -Raw -Encoding UTF8 | ConvertFrom-Json
$paths = Assert-Batch $config

Write-Host ('Validated batch {0}: {1} citation locations.' -f $config.id, $config.jobs.Count)
Write-Host ('Source remains read-only: ' + $paths.Source)
Write-Host ('Target copy: ' + $paths.Target)
if (-not $Apply) {
    Write-Host 'Validation completed. Re-run with -Apply to create and modify the target copy.'
    exit 0
}

if (Test-Path -LiteralPath $paths.Target) {
    throw 'Target document already exists. Use a new batch id and target filename.'
}
[System.IO.Directory]::CreateDirectory($paths.WorkRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($paths.JournalRoot) | Out-Null
Copy-Item -LiteralPath $paths.Source -Destination $paths.Target

$journalPath = Join-Path $paths.JournalRoot ([string]$config.id + '.json')
if (Test-Path -LiteralPath $journalPath) {
    throw 'Batch journal already exists. Use a new batch id.'
}
$journal = [ordered]@{
    batchId = [string]$config.id
    sourceDocument = $paths.Source
    document = $paths.Target
    state = 'starting'
    startedAt = [DateTimeOffset]::Now.ToString('o')
    jobs = @()
}
Write-Journal $journalPath $journal

$client = New-LocalHttpClient
$word = $null
$document = $null
try {
    $status = Invoke-Bridge $client $Endpoint @{ action = 'status' }
    if ([string]$status.state -ne 'ready') {
        throw ('Bridge is not ready: ' + [string]$status.state)
    }
    $session = [string]$status.session
    $pluginBatch = [ordered]@{
        id = [string]$config.id
        collection = [string]$config.collection
        projectRoot = $paths.ProjectRoot
        document = $paths.Target
        jobs = $config.jobs
    }
    Invoke-Bridge $client $Endpoint @{ action = 'prepare'; session = $session; batch = $pluginBatch } | Out-Null

    $word = New-Object -ComObject Word.Application
    $word.Visible = $false
    $word.DisplayAlerts = 0
    $document = $word.Documents.Open($paths.Target, $false, $false)
    $document.Activate()
    $journal.state = 'inserting'
    Write-Journal $journalPath $journal

    foreach ($job in $config.jobs) {
        $before = @(Get-CitationSnapshot $document)
        $anchorStart = Select-Anchor $document $job.anchor
        $result = Invoke-Bridge $client $Endpoint @{
            action = 'insert'
            session = $session
            batchId = [string]$config.id
            id = [string]$job.id
        }
        if ([string]$result.state -ne 'waiting-for-ack') {
            throw ('Unexpected insert state for ' + [string]$job.id + ': ' + [string]$result.state)
        }
        $document.Save()
        $after = @(Get-CitationSnapshot $document)
        if ($after.Count -ne $before.Count + 1) {
            throw ('Citation field count did not increase by one for ' + [string]$job.id)
        }
        if (-not ($after | Where-Object { $_ -match [regex]::Escape([string]$job.key) })) {
            throw ('Saved Zotero field does not contain item key ' + [string]$job.key)
        }
        Invoke-Bridge $client $Endpoint @{
            action = 'ack'
            session = $session
            batchId = [string]$config.id
            id = [string]$job.id
            verified = $true
            citationFieldCount = $after.Count
        } | Out-Null
        $journal.jobs += [ordered]@{
            id = [string]$job.id
            key = [string]$job.key
            anchorStart = $anchorStart
            citationFieldCount = $after.Count
            completedAt = [DateTimeOffset]::Now.ToString('o')
        }
        Write-Journal $journalPath $journal
        Write-Host ('Inserted {0} ({1}/{2}).' -f $job.key, $journal.jobs.Count, $config.jobs.Count)
    }

    $beforeRefresh = @(Get-CitationSnapshot $document)
    $refreshResult = Invoke-Bridge $client $Endpoint @{
        action = 'refresh'
        session = $session
        batchId = [string]$config.id
        id = 'final-refresh'
    }
    if ([string]$refreshResult.state -ne 'waiting-for-ack') {
        throw ('Unexpected refresh state: ' + [string]$refreshResult.state)
    }
    $document.Save()
    $afterRefresh = @(Get-CitationSnapshot $document)
    if ($afterRefresh.Count -ne $beforeRefresh.Count) {
        throw 'Final Zotero refresh changed the citation field count.'
    }
    Invoke-Bridge $client $Endpoint @{
        action = 'ack'
        session = $session
        batchId = [string]$config.id
        id = 'final-refresh'
        verified = $true
        citationFieldCount = $afterRefresh.Count
    } | Out-Null
    $journal.state = 'completed'
    $journal.completedAt = [DateTimeOffset]::Now.ToString('o')
    $journal.finalCitationFieldCount = $afterRefresh.Count
    Write-Journal $journalPath $journal
    Write-Host ('Completed. Verified target: ' + $paths.Target)
}
catch {
    $journal.state = 'failed-do-not-retry'
    $journal.failedAt = [DateTimeOffset]::Now.ToString('o')
    $journal.error = $_.Exception.Message
    Write-Journal $journalPath $journal
    throw
}
finally {
    if ($null -ne $document) {
        try { $document.Close(0) } catch {}
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($document)
    }
    if ($null -ne $word) {
        try { $word.Quit() } catch {}
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($word)
    }
    if ($null -ne $client) {
        $client.Dispose()
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
}
