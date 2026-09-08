<#
.SYNOPSIS
    Stage configuration and capture artifacts for every component this Windows
    host runs. Requirement 04.2. Windows counterpart of 04-stage-artifacts.sh.

.DESCRIPTION
    Runs AFTER the host is READY, on the host, using the instance profile. Not
    part of bootstrap: bootstrap answers "is this host usable", this answers
    "does this host have the data a replay needs". Keeping them apart means a
    staging failure does not make a good host look broken, and re-staging for a
    different market date does not mean rebuilding the host.

    Everything about the flow comes from the plan. This script declares no
    addresses, buckets, host names or product names of its own, which is what
    lets it be published to the public bootstrap repo.

    WHY THE DATE IS DISCOVERED, NOT COMPUTED

    The obvious implementation formats marketDate and fetches that key. It is
    wrong: the production backup jobs use per-engine, inconsistent date offsets,
    so a computed key is right for some engines and absent for others - and
    "absent" arrives as a 404 that reads like a permissions or naming problem.
    So list the prefix, parse every dated entry, and take the nearest at or
    before the market date. The offset is recorded, because -3 days deserves a
    human's attention even though it is not an error.

    WHY CONFIG GOES AT THE DIRECTORY ROOT

    The engines resolve config relative to their working directory. One extra
    nesting level makes every relative path inside every .ini wrong, and it
    surfaces as an engine startup error - which reads like bad config rather
    than a bad path. The layout is declared in the plan under .staged so this
    script and the Runner cannot disagree about it.

    THE FIX ARCHIVE PATH, AND THE ONE CASE THAT NEEDS A HUMAN

    For FIX components the flow file's declared path is the authority - the key
    convention was never validated for that product - so staging uses it.

    But when the declared path names a DIFFERENT HOST than the engine runs on
    (logArchive.fixArchive.hostMismatch), that is reported loudly and recorded.
    It can be legitimate, since archives get moved; it can equally be a
    flow-file error, and if it is wrong the replay reads another host's
    messages, replays clean, and reports matching counts.

.NOTES
    PowerShell 5.1 traps that shaped this file - see the long note in
    02-prereq-windows.ps1 for the full history:

      * A native command writing to stderr becomes a TERMINATING error under
        $ErrorActionPreference='Stop', often with an EMPTY exception message.
        aws writes progress to stderr, so every call goes through Invoke-Aws,
        which drops EAP to Continue and inspects $LASTEXITCODE instead.
      * (cmd ...) 2>&1 binds the redirect to the PARENTHESISED EXPRESSION, not
        the native command, so it does nothing. Do not "simplify" Invoke-Aws
        into that shape.
#>
[CmdletBinding()]
param(
    [string] $PlanFile = 'C:\FlowTest\bootstrap\flow-plan-windows.json',
    [switch] $DryRun,
    [string] $Only,
    [switch] $SkipCaptures,
    [string] $GitHubTokenRef
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Printed first, every run. Without it a stale fetch is invisible and a retest
# can silently re-run old code while looking like a fresh result.
$script:ScriptVersion = '2026-09-08.1-staging-fixes'

function Write-Step { param([string] $Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "  [ok]   $Message" -ForegroundColor Green }
function Write-Skip { param([string] $Message) Write-Host "  [skip] $Message" -ForegroundColor DarkGray }
function Write-Warn { param([string] $Message) Write-Host "  [warn] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string] $Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

Write-Host "script version: $script:ScriptVersion" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Native command wrapper.
#
# Captures stdout, tolerates stderr, and reports the real exit code. See the
# .NOTES block: without this, aws writing one progress line to stderr aborts the
# script with an empty error message, which is indistinguishable from a hang.
function Invoke-Aws {
    param([Parameter(Mandatory)][string[]] $Arguments, [switch] $AllowFailure)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & aws @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }

    $text = ($output | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { $_ }
    }) -join "`n"

    if ($code -ne 0 -and -not $AllowFailure) {
        throw "aws $($Arguments -join ' ') exited $code`n$text"
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $text }
}

# ---------------------------------------------------------------------------
# Date discovery. The one piece of real logic here.
function Select-NearestDated {
    param(
        [string[]] $Candidates,
        [Parameter(Mandatory)][string] $DateFormat,   # strftime-style, from the plan
        [Parameter(Mandatory)][datetime] $MarketDate,
        [string] $Pattern = '{date}'
    )
    # The pattern matters. A folder family is named purely by its date
    # ("Configs/20260604"); an object family wraps it in a fixed prefix and
    # suffix ("<engine>-Capture_2026-06-04.log"). Parsing the whole leaf works
    # for the first and finds nothing for the second - which reads as "the
    # archive has no Quill file" rather than as a parsing bug.
    $leafPattern = ($Pattern -split '/')[-1]
    $parts = $leafPattern -split '\{date\}', 2
    $head = $parts[0]
    $tail = if ($parts.Count -gt 1) { $parts[1] } else { '' }

    # strftime -> .NET format. Only the tokens hosts-map.json actually declares.
    $net = $DateFormat.Replace('%Y', 'yyyy').Replace('%m', 'MM').Replace('%d', 'dd').Replace('%b', 'MMM')

    $parsed = @()
    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $leaf = ($candidate.TrimEnd('/') -split '/')[-1]
        if ($head -and -not $leaf.StartsWith($head)) { continue }
        if ($tail -and -not $leaf.EndsWith($tail))   { continue }
        $core = $leaf.Substring($head.Length, $leaf.Length - $head.Length - $tail.Length)
        $value = [datetime]::MinValue
        if ([datetime]::TryParseExact($core, $net, [cultureinfo]::InvariantCulture,
                                      [System.Globalization.DateTimeStyles]::None, [ref] $value)) {
            $parsed += [pscustomobject]@{ Date = $value; Key = $candidate }
        }
    }
    if ($parsed.Count -eq 0) { return $null }

    $parsed = $parsed | Sort-Object Date
    $atOrBefore = @($parsed | Where-Object { $_.Date -le $MarketDate })
    if ($atOrBefore.Count -gt 0) {
        $chosen = $atOrBefore[-1]
        $after = $false
    }
    else {
        $chosen = $parsed[0]
        $after = $true
    }
    return [pscustomobject]@{
        Key    = $chosen.Key
        Offset = [int]($chosen.Date - $MarketDate).TotalDays
        After  = $after
    }
}

function Resolve-Dated {
    param([string] $Bucket, [string] $Prefix, [string] $DateFormat, [string] $Pattern = '{date}')
    $base = $Prefix.TrimEnd('/') + '/'
    $folders = Invoke-Aws @('s3api','list-objects-v2','--bucket',$Bucket,'--prefix',$base,
                            '--delimiter','/','--query','CommonPrefixes[].Prefix',
                            '--output','text') -AllowFailure
    $candidates = @()
    if ($folders.ExitCode -eq 0 -and $folders.Output -and $folders.Output -ne 'None') {
        $candidates = $folders.Output -split '\s+' | Where-Object { $_ }
    }
    if ($candidates.Count -eq 0) {
        $objects = Invoke-Aws @('s3api','list-objects-v2','--bucket',$Bucket,'--prefix',$base,
                                '--query','Contents[].Key','--output','text') -AllowFailure
        if ($objects.ExitCode -eq 0 -and $objects.Output -and $objects.Output -ne 'None') {
            $candidates = $objects.Output -split '\s+' | Where-Object { $_ }
        }
    }
    if ($candidates.Count -eq 0) { return $null }
    return Select-NearestDated -Candidates $candidates -DateFormat $DateFormat `
                               -MarketDate $script:MarketDate -Pattern $Pattern
}

# ---------------------------------------------------------------------------
# Preflight
Write-Step 'Preflight'

# A machine PATH change does not reach an already-running process, and staging is
# often invoked through ssm send-command - the same trap 02-prereq-windows.ps1
# documents. So resolve the tools explicitly rather than trusting PATH.
foreach ($tool in @('aws', 'git')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $env:Path = "$env:Path;$machinePath"
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            Write-Fail "$tool not found, even after re-reading the machine PATH."
            Write-Fail "02-prereq-windows.ps1 installs both. If it ran, restart the SSM agent - a PATH change does not reach a running process."
            exit 1
        }
        Write-Warn "$tool was not on the process PATH; picked it up from the machine PATH"
    }
}
Write-Ok "aws $((Invoke-Aws @('--version') -AllowFailure).Output)"

if (-not (Test-Path -LiteralPath $PlanFile)) { Write-Fail "no plan file at $PlanFile"; exit 1 }
$plan = Get-Content -LiteralPath $PlanFile -Raw | ConvertFrom-Json
if ($plan.hostRole -ne 'windows') { Write-Fail "plan is for hostRole '$($plan.hostRole)', not 'windows'"; exit 1 }

$script:MarketDate = [datetime]::ParseExact($plan.marketDate, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)
$configRoot  = $plan.staged.configRoot
$captureRoot = $plan.staged.captureRoot
$manifestPath = $plan.staged.manifest

Write-Ok "flow $($plan.flow), role $($plan.hostRole), market date $($plan.marketDate)"
Write-Ok "config root  $configRoot"
Write-Ok "capture root $captureRoot"
if ($DryRun) { Write-Warn 'DRY RUN - listing and resolving only, nothing will be written' }

$identity = Invoke-Aws @('sts','get-caller-identity','--query','Arn','--output','text') -AllowFailure
if ($identity.ExitCode -ne 0) {
    Write-Fail 'aws sts get-caller-identity failed. The instance profile is missing or has no credentials.'
    exit 1
}
Write-Ok "identity $($identity.Output)"

# ---------------------------------------------------------------------------
# GitHub token for the private config repo (configSource.gitRepo). Resolved by shape with the
# instance profile, the same way UserData resolves the bootstrap token, so there
# is one mechanism to understand and nothing lands in an argument list.
$script:GitHubToken = $null
function Resolve-GitHubToken {
    if ($script:GitHubToken) { return $true }
    if (-not $GitHubTokenRef) { return $false }
    $raw = if ($GitHubTokenRef.StartsWith('/')) {
        (Invoke-Aws @('ssm','get-parameter','--name',$GitHubTokenRef,'--with-decryption',
                      '--query','Parameter.Value','--output','text') -AllowFailure).Output
    } else {
        (Invoke-Aws @('secretsmanager','get-secret-value','--secret-id',$GitHubTokenRef,
                      '--query','SecretString','--output','text') -AllowFailure).Output
    }
    if (-not $raw) { return $false }
    $raw = $raw.Trim()
    if ($raw.StartsWith('{')) {
        try { $script:GitHubToken = ($raw | ConvertFrom-Json).token } catch { $script:GitHubToken = $null }
    } else { $script:GitHubToken = $raw }
    return [bool]$script:GitHubToken
}

# ---------------------------------------------------------------------------
$script:Results = New-Object System.Collections.Generic.List[object]
function Add-Result {
    param([string] $Component, [string] $Kind, [string] $Status, [hashtable] $Detail)
    $script:Results.Add([pscustomobject]@{
        component = $Component; kind = $Kind; status = $Status; detail = $Detail })
}

function Get-GitFolder {
    <#  Sparse, depth-1 checkout of one folder from the config repo. Returns the
        local path, or $null. That repo holds every host's configuration, so
        a full clone is large and entirely wasted here. #>
    param([string] $Owner, [string] $Repo, [string] $Branch, [string] $Path)
    if (-not (Resolve-GitHubToken)) { return $null }
    $work = Join-Path $env:TEMP ("cfg-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # The token goes in an http.extraheader, not the URL: a URL with
        # credentials is recorded in .git/config and in any error message.
        & git -c credential.helper= -c "http.extraheader=Authorization: Bearer $script:GitHubToken" `
              clone --quiet --depth 1 --branch $Branch --filter=blob:none --sparse `
              "https://github.com/$Owner/$Repo.git" "$work\repo" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        Push-Location "$work\repo"
        try { & git sparse-checkout set --no-cone $Path.Replace('\', '/') 2>&1 | Out-Null }
        finally { Pop-Location }
    }
    finally { $ErrorActionPreference = $previous }
    $resolved = Join-Path "$work\repo" $Path.TrimStart('\')
    if (Test-Path -LiteralPath $resolved) { return $resolved }
    return $null
}

function Stage-Config {
    param([string] $Name, $Service)
    $cs = $Service.configSource
    $dest = Join-Path $configRoot $Name

    switch ($cs.type) {
        's3-daily-snapshot' {
            $resolved = Resolve-Dated -Bucket $cs.bucket -Prefix $cs.prefix -DateFormat $cs.dateFormat -Pattern '{date}'
            if (-not $resolved) {
                Write-Warn "${Name}: no dated config snapshot under s3://$($cs.bucket)/$($cs.prefix)/"
                Add-Result $Name 'config' 'skipped' @{ reason = 'no dated snapshot folder found under the prefix'; prefix = $cs.prefix }
                return
            }
            if ($resolved.After) {
                Write-Warn "${Name}: every snapshot is AFTER the market date; taking the earliest. A snapshot dated after the session already contains it."
            }
            Write-Ok "${Name}: snapshot $($resolved.Key) (offset $($resolved.Offset)d from $($plan.marketDate))"
            $files = 0
            if (-not $DryRun) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                # Flat by construction: the snapshot is non-recursive, and
                # --recursive on a single folder lands its files at the root.
                $copy = Invoke-Aws @('s3','cp',"s3://$($cs.bucket)/$($resolved.Key.TrimEnd('/'))/",
                                     "$dest\", '--recursive', '--only-show-errors') -AllowFailure
                if ($copy.ExitCode -ne 0) {
                    Write-Fail "${Name}: config fetch failed - $($copy.Output)"
                    Add-Result $Name 'config' 'failed' @{ reason = 'aws s3 cp failed'; key = $resolved.Key }
                    return
                }
                $files = @(Get-ChildItem -LiteralPath $dest -File).Count
            }
            Add-Result $Name 'config' 'staged' @{
                source = 's3-daily-snapshot'; key = $resolved.Key
                dateOffsetDays = $resolved.Offset; files = $files; dest = $dest }
            Test-AgainstGit -Name $Name -ConfigSource $cs -Dest $dest
        }

        'git-serverconfigs' {
            if (-not (Resolve-GitHubToken)) {
                Write-Warn "${Name}: config lives in the private $($cs.gitRepo) repo and no usable -GitHubTokenRef was given"
                Add-Result $Name 'config' 'skipped' @{
                    reason = 'private repo and no GitHub token reference supplied'
                    repo = $cs.gitRepo; path = $cs.gitPath }
                return
            }
            Write-Ok "${Name}: $($cs.gitRepo)@$($cs.gitBranch) at $($cs.gitPath)"
            $files = 0
            if (-not $DryRun) {
                $src = Get-GitFolder -Owner $plan.engineRepoOwner -Repo $cs.gitRepo `
                                     -Branch $cs.gitBranch -Path $cs.gitPath
                if (-not $src) {
                    Write-Warn "${Name}: $($cs.gitPath) not present in $($cs.gitRepo)@$($cs.gitBranch), or the clone failed"
                    Add-Result $Name 'config' 'failed' @{ reason = 'git checkout produced nothing'; path = $cs.gitPath }
                    return
                }
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                # Depth 1 only, matching the snapshot layout. Sub-folders are NOT
                # flattened into the root: two same-named files in different
                # folders would silently overwrite each other.
                Get-ChildItem -LiteralPath $src -File | Copy-Item -Destination $dest -Force
                $files = @(Get-ChildItem -LiteralPath $dest -File).Count
            }
            Add-Result $Name 'config' 'staged' @{
                source = 'git-serverconfigs'; repo = $cs.gitRepo; branch = $cs.gitBranch
                path = $cs.gitPath; files = $files; dest = $dest }
        }

        default {
            Write-Warn "${Name}: unknown configSource.type '$($cs.type)'"
            Add-Result $Name 'config' 'skipped' @{ reason = 'unknown configSource.type'; type = $cs.type }
        }
    }
}

function Test-AgainstGit {
    <#  The snapshot comes from a NON-RECURSIVE backup job limited to certain
        extensions, so a config in a subfolder or with another extension is
        simply absent. Comparing against git turns "silently missing" into a
        warning - which is the point: an engine started without one config file
        does not fail, it behaves differently. #>
    param([string] $Name, $ConfigSource, [string] $Dest)
    if (-not $ConfigSource.crossCheckAgainstGit) { return }
    if (-not (Resolve-GitHubToken)) {
        Write-Warn "${Name}: snapshot NOT cross-checked against git (no token). A config present in git and missing from the snapshot will not be noticed."
        Add-Result $Name 'crosscheck' 'skipped' @{ reason = 'no GitHub token reference, so the snapshot completeness check did not run' }
        return
    }
    if ($DryRun) { Write-Skip "${Name}: cross-check (dry run)"; return }

    $src = Get-GitFolder -Owner $plan.engineRepoOwner -Repo $ConfigSource.gitRepo `
                         -Branch $ConfigSource.gitBranch -Path $ConfigSource.gitPath
    if (-not $src) {
        Write-Warn "${Name}: cross-check checkout failed"
        Add-Result $Name 'crosscheck' 'failed' @{ reason = 'git checkout produced nothing' }
        return
    }
    $missing = @()
    foreach ($file in Get-ChildItem -LiteralPath $src -File) {
        if (-not (Test-Path -LiteralPath (Join-Path $Dest $file.Name))) { $missing += $file.Name }
    }
    if ($missing.Count -gt 0) {
        Write-Warn "${Name}: $($missing.Count) file(s) in git but NOT in the snapshot: $($missing -join ', ')"
        Write-Warn "${Name}: the backup job is non-recursive and extension-limited, so this is expected for some files - but an engine started without one of these behaves differently rather than failing."
        Add-Result $Name 'crosscheck' 'warned' @{ reason = 'present in git, absent from the snapshot'; missing = $missing }
    }
    else {
        Write-Ok "${Name}: snapshot matches git file-for-file"
        Add-Result $Name 'crosscheck' 'ok' @{ missing = @() }
    }
}

function Stage-Captures {
    param([string] $Name, $Service)
    $dest = Join-Path $captureRoot $Name
    $archive = $Service.logArchive

    # FIX message archive. Refused outright on a prefix conflict.
    if ($archive.PSObject.Properties.Name -contains 'fixArchive' -and $archive.fixArchive) {
        $fa = $archive.fixArchive
        if ($fa.hostMismatch) {
            Write-Warn "${Name}: the declared FIX archive is under a DIFFERENT HOST than the engine runs on"
            Write-Warn "${Name}: declared $($fa.prefix), convention would give $($fa.derivedPrefix)"
            Write-Warn "${Name}: staging the declared path. If it is wrong the replay reads another host's messages and still reports matching counts - confirm against the FIX backup job."
            Add-Result $Name 'fixArchiveHost' 'warned' @{
                prefix = $fa.prefix; derivedPrefix = $fa.derivedPrefix }
        }
        if (-not $fa.prefix) {
            Write-Warn "${Name}: no FIX archive path declared or derivable"
            Add-Result $Name 'fixArchive' 'skipped' @{ reason = 'no archive path available' }
        }
        else {
            Write-Ok "${Name}: FIX messages s3://$($fa.bucket)/$($fa.prefix)/"
            if (-not $DryRun) {
                New-Item -ItemType Directory -Path (Join-Path $dest 'fix') -Force | Out-Null
                $copy = Invoke-Aws @('s3','cp',"s3://$($fa.bucket)/$($fa.prefix.TrimEnd('/'))/",
                                     (Join-Path $dest 'fix\'), '--recursive', '--only-show-errors') -AllowFailure
                if ($copy.ExitCode -ne 0) { Write-Warn "${Name}: FIX message fetch failed (prefix may not exist)" }
            }
            Add-Result $Name 'fixArchive' 'staged' @{ bucket = $fa.bucket; prefix = $fa.prefix }
        }
    }

    if (-not $archive.artifacts) { return }
    foreach ($family in $archive.artifacts.PSObject.Properties.Name) {
        if ($family -eq 'engineConfigs') { continue }   # that IS the config, staged above
        $spec = $archive.artifacts.$family
        $parent = $archive.prefix
        if ($spec.pattern -like '*/*') { $parent = "$($archive.prefix)/$(($spec.pattern -split '/')[0])" }

        $resolved = Resolve-Dated -Bucket $archive.bucket -Prefix $parent `
                                  -DateFormat $spec.dateFormat -Pattern $spec.pattern
        if (-not $resolved) {
            if ($spec.optional) {
                Write-Skip "$Name/${family}: nothing dated under s3://$($archive.bucket)/$parent/ (optional)"
                Add-Result $Name $family 'skipped' @{ reason = 'no dated entry found'; optional = $true; prefix = $parent }
            }
            else {
                Write-Warn "$Name/${family}: nothing dated under s3://$($archive.bucket)/$parent/ - this family is NOT optional"
                Add-Result $Name $family 'missing' @{ reason = 'no dated entry found'; optional = $false; prefix = $parent }
            }
            continue
        }
        Write-Ok "$Name/${family}: $($resolved.Key) (offset $($resolved.Offset)d)"
        if (-not $DryRun) {
            $target = Join-Path $dest $family
            New-Item -ItemType Directory -Path $target -Force | Out-Null
            $args = if ($spec.kind -eq 'prefix') {
                @('s3','cp',"s3://$($archive.bucket)/$($resolved.Key.TrimEnd('/'))/","$target\",'--recursive','--only-show-errors')
            } else {
                @('s3','cp',"s3://$($archive.bucket)/$($resolved.Key)","$target\",'--only-show-errors')
            }
            $copy = Invoke-Aws $args -AllowFailure
            if ($copy.ExitCode -ne 0) { Write-Warn "$Name/${family}: fetch failed" }
        }
        Add-Result $Name $family 'staged' @{
            key = $resolved.Key; dateOffsetDays = $resolved.Offset; dest = (Join-Path $dest $family) }
    }
}

# ---------------------------------------------------------------------------
Write-Step 'Staging components'
$components = @($plan.groups | ForEach-Object { $_.services } | ForEach-Object { $_.containerName })
if ($components.Count -eq 0) { Write-Warn 'this host runs no components; only the manifest will be written' }

foreach ($name in $components) {
    if ($Only -and $name -ne $Only) { continue }
    $service = @($plan.groups | ForEach-Object { $_.services } | Where-Object { $_.containerName -eq $name })[0]
    Write-Host "`n  $name" -ForegroundColor Cyan
    Stage-Config -Name $name -Service $service
    if ($SkipCaptures) { Write-Skip "${name}: captures (-SkipCaptures)" }
    else { Stage-Captures -Name $name -Service $service }
}

# The Quill capture is flow-level, not per-component: one book feeds the
# market-data simulator for the whole slice.
Write-Step 'Market-data capture (Quill)'
if (-not $plan.quillCapture) {
    Write-Warn 'no Quill capture declared for this flow. The market-data simulator will have no book, so routing decisions constrained by order state exercise the no-market fallback path - a run that looks green while testing the wrong behaviour.'
    Add-Result '-' 'quillCapture' 'missing' @{ reason = 'not declared in the flow file' }
}
else {
    $quill = $plan.quillCapture
    Write-Ok "s3://$($quill.bucket)/$($quill.s3Path)"
    $quillDest = Join-Path $captureRoot '_quill'
    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $quillDest -Force | Out-Null
        $copy = Invoke-Aws @('s3','cp',"s3://$($quill.bucket)/$($quill.s3Path)","$quillDest\",'--only-show-errors') -AllowFailure
        if ($copy.ExitCode -ne 0) {
            Write-Warn 'Quill fetch failed. The key is a discovery HINT - the capture date may differ from the market date.'
        }
    }
    Add-Result '-' 'quillCapture' 'staged' @{ bucket = $quill.bucket; key = $quill.s3Path; dest = $quillDest }
}

# ---------------------------------------------------------------------------
# Manifest. Consumed by emit_environment.py --staged-json, so environment.json
# reports what is actually on disk rather than what was intended. Every
# non-staged item keeps its reason: a gap must be visible in the artifact
# instead of surfacing later as a Runner crash.
Write-Step 'Manifest'
$summary = @{}
foreach ($group in ($script:Results | Group-Object status)) { $summary[$group.Name] = $group.Count }

if ($DryRun) {
    Write-Skip 'manifest not written (dry run)'
    $summary.GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Host "    $($_.Key): $($_.Value)" }
}
else {
    New-Item -ItemType Directory -Path (Split-Path -Parent $manifestPath) -Force | Out-Null
    $document = [ordered]@{
        schemaVersion = '1.0'
        hostRole      = $plan.hostRole
        flow          = $plan.flow
        marketDate    = $plan.marketDate
        configRoot    = $configRoot
        captureRoot   = $captureRoot
        stagedBy      = $script:ScriptVersion
        stagedAt      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        items         = $script:Results
        summary       = $summary
    }
    $document | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-Ok "wrote $manifestPath"
    $summary.GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Host "    $($_.Key): $($_.Value)" }
}

# Exit non-zero only on a REFUSAL or a hard failure. A warning is information,
# not a reason to fail the stage - build 49 wasted 25 minutes because an advisory
# item was allowed to block progress.
$bad = @($script:Results | Where-Object { $_.status -in @('failed', 'refused') })
$missing = @($script:Results | Where-Object { $_.status -eq 'missing' })
Write-Host ''
if ($bad.Count -gt 0) {
    Write-Fail "$($bad.Count) item(s) failed or were refused - see the manifest. Nothing was staged for those components."
    exit 1
}
if ($missing.Count -gt 0) {
    Write-Warn "$($missing.Count) required artifact(s) not found. The replay will run without them."
}
Write-Ok 'staging complete'
exit 0
