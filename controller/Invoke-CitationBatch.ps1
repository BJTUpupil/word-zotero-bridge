[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BatchPath,

    [switch]$Apply,

    [switch]$Resume,

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
    $seenInsert = $false
    foreach ($job in $Config.jobs) {
        if ([string]$job.id -notmatch '^[A-Za-z0-9_-]{1,80}$' -or [string]$job.id -eq 'final-refresh') {
            throw 'Invalid job id.'
        }
        if ($ids.ContainsKey([string]$job.id)) {
            throw ('Duplicate job id: ' + [string]$job.id)
        }
        $ids[[string]$job.id] = $true
        $action = if ([string]::IsNullOrWhiteSpace([string]$job.action)) { 'insert' } else { [string]$job.action }
        if ($action -notin @('insert', 'replace')) { throw ('Invalid job action: ' + [string]$job.id) }
        if ($action -eq 'insert') { $seenInsert = $true }
        if ($action -eq 'replace' -and $seenInsert) { throw 'Replacement jobs must precede insertion jobs.' }
        if ($action -eq 'insert') {
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
        } else {
            if ([int]$job.fieldOrdinal -lt 1) {
                throw ('Invalid citation field ordinal: ' + [string]$job.id)
            }
            if ($null -eq $job.expectedKeys -or $job.expectedKeys.Count -lt 1) {
                throw ('Missing expected citation keys: ' + [string]$job.id)
            }
            foreach ($expectedKey in $job.expectedKeys) {
                if ([string]$expectedKey -notmatch '^[A-Z0-9]{8}$') {
                    throw ('Invalid expected citation key: ' + [string]$job.id)
                }
            }
            if ($null -eq $job.replacements -or $job.replacements.Count -lt 1 -or $job.replacements.Count -gt 10) {
                throw ('Invalid replacements: ' + [string]$job.id)
            }
            foreach ($replacement in $job.replacements) {
                if ([string]$replacement.oldKey -notmatch '^[A-Z0-9]{8}$' -or [string]$replacement.key -notmatch '^[A-Z0-9]{8}$') {
                    throw ('Invalid replacement key: ' + [string]$job.id)
                }
                if ([string]::IsNullOrWhiteSpace([string]$replacement.title) -or $null -eq $replacement.doi) {
                    throw ('Incomplete replacement identity: ' + [string]$job.id)
                }
            }
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

function Get-CitationKeysFromCode([string]$Code) {
    return @([regex]::Matches($Code, '/items/([A-Z0-9]{8})') | ForEach-Object { $_.Groups[1].Value })
}

function Select-CitationField($Document, [int]$FieldOrdinal, $ExpectedKeys) {
    $citationIndex = 0
    for ($index = 1; $index -le $Document.Fields.Count; $index++) {
        $field = $Document.Fields.Item($index)
        $code = [string]$field.Code.Text
        if ($code -match 'ZOTERO_ITEM\s+CSL_CITATION') {
            $citationIndex++
            if ($citationIndex -eq $FieldOrdinal) {
                $actualSignature = (Get-CitationKeysFromCode $code) -join '|'
                $expectedSignature = @($ExpectedKeys) -join '|'
                if ($actualSignature -ne $expectedSignature) {
                    throw ('Citation item list changed before job at field ordinal ' + $FieldOrdinal)
                }
                $field.Result.Select()
                return $FieldOrdinal
            }
        }
    }
    throw ('Citation field ordinal not found: ' + $FieldOrdinal)
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

function Get-CitationKeySignature([string]$Code) {
    $keys = @(Get-CitationKeysFromCode $Code)
    return ($keys -join '|')
}

function Get-KeyOccurrenceCount($Snapshot, [string]$Key) {
    $count = 0
    foreach ($code in $Snapshot) {
        $count += @((Get-CitationKeysFromCode ([string]$code)) | Where-Object { $_ -eq $Key }).Count
    }
    return $count
}

function Get-ExpectedReplacementKeys($Job) {
    return @($Job.expectedKeys | ForEach-Object {
        $currentKey = [string]$_
        $replacement = @($Job.replacements | Where-Object { [string]$_.oldKey -eq $currentKey })
        if ($replacement.Count -eq 1) { [string]$replacement[0].key } else { $currentKey }
    })
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

[System.IO.Directory]::CreateDirectory($paths.WorkRoot) | Out-Null
[System.IO.Directory]::CreateDirectory($paths.JournalRoot) | Out-Null
$journalPath = Join-Path $paths.JournalRoot ([string]$config.id + '.json')
if ($Resume) {
    if (-not (Test-Path -LiteralPath $paths.Target -PathType Leaf) -or -not (Test-Path -LiteralPath $journalPath -PathType Leaf)) {
        throw 'Resume requires the existing target document and matching journal.'
    }
    $savedJournal = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]$savedJournal.batchId -ne [string]$config.id -or
        -not ([string]$savedJournal.document).Equals($paths.Target, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'The existing journal does not match this batch and target document.'
    }
    $journal = [ordered]@{
        batchId = [string]$savedJournal.batchId
        sourceDocument = [string]$savedJournal.sourceDocument
        document = [string]$savedJournal.document
        state = 'resuming'
        startedAt = [string]$savedJournal.startedAt
        jobs = @($savedJournal.jobs)
        pending = $savedJournal.pending
        resumedAt = [DateTimeOffset]::Now.ToString('o')
    }
} else {
    if (Test-Path -LiteralPath $paths.Target) {
        throw 'Target document already exists. Use -Resume or choose a new batch id and target filename.'
    }
    if (Test-Path -LiteralPath $journalPath) {
        throw 'Batch journal already exists. Use -Resume or choose a new batch id.'
    }
    Copy-Item -LiteralPath $paths.Source -Destination $paths.Target
    $journal = [ordered]@{
        batchId = [string]$config.id
        sourceDocument = $paths.Source
        document = $paths.Target
        state = 'starting'
        startedAt = [DateTimeOffset]::Now.ToString('o')
        jobs = @()
        pending = $null
    }
}
Write-Journal $journalPath $journal

$client = New-LocalHttpClient
$word = $null
$document = $null
$session = $null
try {
    $status = Invoke-Bridge $client $Endpoint @{ action = 'status' }
    $session = [string]$status.session
    if ([string]$status.state -ne 'ready') {
        $status = Invoke-Bridge $client $Endpoint @{ action = 'reset'; session = $session }
        if ([string]$status.state -ne 'ready') { throw ('Bridge reset failed: ' + [string]$status.state) }
    }

    $word = New-Object -ComObject Word.Application
    $word.Visible = $false
    $word.DisplayAlerts = 0
    $document = $word.Documents.Open($paths.Target, $false, $false)
    $document.Activate()
    if ($Resume -and $null -ne $journal.pending) {
        $pendingId = [string]$journal.pending.id
        $pendingJob = @($config.jobs | Where-Object { [string]$_.id -eq $pendingId })
        if ($pendingJob.Count -ne 1) { throw ('Pending journal job is absent from the batch: ' + $pendingId) }
        $snapshot = @(Get-CitationSnapshot $document)
        $pendingApplied = $false
        if ([string]$journal.pending.action -eq 'replace') {
            $targetIndex = [int]$pendingJob[0].fieldOrdinal - 1
            if ($targetIndex -lt 0 -or $targetIndex -ge $snapshot.Count) { throw 'Pending replacement field ordinal is unavailable.' }
            $actual = Get-CitationKeySignature ([string]$snapshot[$targetIndex])
            $beforeExpected = @($pendingJob[0].expectedKeys) -join '|'
            $afterExpected = @(Get-ExpectedReplacementKeys $pendingJob[0]) -join '|'
            if ($actual -eq $afterExpected) { $pendingApplied = $true }
            elseif ($actual -ne $beforeExpected) { throw ('Pending replacement has an indeterminate citation state: ' + $pendingId) }
        } else {
            $currentCount = Get-KeyOccurrenceCount $snapshot ([string]$pendingJob[0].key)
            $beforeCount = [int]$journal.pending.beforeKeyCount
            if ($currentCount -eq $beforeCount + 1) { $pendingApplied = $true }
            elseif ($currentCount -ne $beforeCount) { throw ('Pending insertion has an indeterminate citation state: ' + $pendingId) }
        }
        if ($pendingApplied) {
            $journal.jobs += [ordered]@{
                id = $pendingId
                action = [string]$journal.pending.action
                recovered = $true
                completedAt = [DateTimeOffset]::Now.ToString('o')
            }
        }
        $journal.pending = $null
        Write-Journal $journalPath $journal
    }

    $completedIds = @{}
    foreach ($completedJob in @($journal.jobs)) { $completedIds[[string]$completedJob.id] = $true }
    $remainingJobs = @($config.jobs | Where-Object { -not $completedIds.ContainsKey([string]$_.id) })
    if ($remainingJobs.Count -gt 0) {
        $pluginBatch = [ordered]@{
            id = [string]$config.id
            collection = [string]$config.collection
            projectRoot = $paths.ProjectRoot
            document = $paths.Target
            jobs = $remainingJobs
        }
        Invoke-Bridge $client $Endpoint @{ action = 'prepare'; session = $session; batch = $pluginBatch } | Out-Null
    }
    $journal.state = 'editing'
    Write-Journal $journalPath $journal

    foreach ($job in $remainingJobs) {
        $action = if ([string]::IsNullOrWhiteSpace([string]$job.action)) { 'insert' } else { [string]$job.action }
        $before = @(Get-CitationSnapshot $document)
        $locator = if ($action -eq 'replace') {
            Select-CitationField $document ([int]$job.fieldOrdinal) $job.expectedKeys
        } else {
            Select-Anchor $document $job.anchor
        }
        $journal.pending = [ordered]@{
            id = [string]$job.id
            action = $action
            beforeKeyCount = if ($action -eq 'insert') { Get-KeyOccurrenceCount $before ([string]$job.key) } else { $null }
            startedAt = [DateTimeOffset]::Now.ToString('o')
        }
        Write-Journal $journalPath $journal
        $result = Invoke-Bridge $client $Endpoint @{
            action = $action
            session = $session
            batchId = [string]$config.id
            id = [string]$job.id
        }
        if ([string]$result.state -ne 'waiting-for-ack') {
            throw ('Unexpected mutation state for ' + [string]$job.id + ': ' + [string]$result.state)
        }
        $document.Save()
        $after = @(Get-CitationSnapshot $document)
        if ($action -eq 'insert') {
            if ($after.Count -lt $before.Count -or $after.Count -gt $before.Count + 1) {
                throw ('Unexpected citation field count after insertion for ' + [string]$job.id)
            }
            if ((Get-KeyOccurrenceCount $after ([string]$job.key)) -ne (Get-KeyOccurrenceCount $before ([string]$job.key)) + 1) {
                throw ('Citation item count did not increase by one for ' + [string]$job.id)
            }
        } else {
            if ($after.Count -ne $before.Count) {
                throw ('Citation field count changed during replacement for ' + [string]$job.id)
            }
            $targetIndex = [int]$job.fieldOrdinal - 1
            $expectedAfter = @(Get-ExpectedReplacementKeys $job)
            for ($snapshotIndex = 0; $snapshotIndex -lt $after.Count; $snapshotIndex++) {
                $beforeSignature = Get-CitationKeySignature ([string]$before[$snapshotIndex])
                $afterSignature = Get-CitationKeySignature ([string]$after[$snapshotIndex])
                if ($snapshotIndex -eq $targetIndex) {
                    if ($afterSignature -ne ($expectedAfter -join '|')) {
                        throw ('Replacement item list mismatch for ' + [string]$job.id)
                    }
                } elseif ($beforeSignature -ne $afterSignature) {
                    throw ('An unrelated citation item list changed during ' + [string]$job.id)
                }
            }
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
            action = $action
            key = if ($action -eq 'insert') { [string]$job.key } else { $null }
            locator = $locator
            citationFieldCount = $after.Count
            completedAt = [DateTimeOffset]::Now.ToString('o')
        }
        $journal.pending = $null
        Write-Journal $journalPath $journal
        Write-Host ('Completed {0} ({1}/{2}).' -f $job.id, $journal.jobs.Count, $config.jobs.Count)
    }

    if ($remainingJobs.Count -gt 0) {
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
        for ($refreshIndex = 0; $refreshIndex -lt $afterRefresh.Count; $refreshIndex++) {
            if ((Get-CitationKeySignature ([string]$beforeRefresh[$refreshIndex])) -ne (Get-CitationKeySignature ([string]$afterRefresh[$refreshIndex]))) {
                throw 'Final Zotero refresh changed citation item membership.'
            }
        }
        Invoke-Bridge $client $Endpoint @{
            action = 'ack'
            session = $session
            batchId = [string]$config.id
            id = 'final-refresh'
            verified = $true
            citationFieldCount = $afterRefresh.Count
        } | Out-Null
    }
    $finalCitationFieldCount = if ($remainingJobs.Count -gt 0) { $afterRefresh.Count } else { @(Get-CitationSnapshot $document).Count }
    $journal.state = 'completed'
    $journal.completedAt = [DateTimeOffset]::Now.ToString('o')
    $journal.finalCitationFieldCount = $finalCitationFieldCount
    Write-Journal $journalPath $journal
    Write-Host ('Completed. Verified target: ' + $paths.Target)
}
catch {
    if ($null -ne $session) {
        try { Invoke-Bridge $client $Endpoint @{ action = 'reset'; session = $session } | Out-Null } catch {}
    }
    $journal.state = 'failed-resumable'
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
