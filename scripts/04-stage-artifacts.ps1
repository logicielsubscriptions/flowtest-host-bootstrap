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
    [string] $ConfigRepoTokenRef,
    # Days either side of the market date to accept a dated archive folder.
    # 3 covers a weekend plus the observed next-morning backup offset without
    # pulling the years of history under the same prefix. Matches
    # --archive-window-days in 04-stage-artifacts.sh.
    [ValidateRange(0, 365)]
    [int] $ArchiveWindowDays = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# TWO JOBS, AND THE SECOND ONE MATTERS MORE.
#
# Build 76: this script hit a strict-mode error, PowerShell printed
#     The property 'Name' cannot be found on this object.
#     FullyQualifiedErrorId : PropertyNotFoundStrict
# and the process still exited 0, because `powershell -File` reports the
# INTERPRETER's exit status, not whether the script finished. So:
#   * SSM recorded Status=Success
#   * the pipeline echoed "windows: staging status Success"
#   * no manifest was written, and the build was green
# A host staged nothing and every layer above it said the environment was ready.
#
# 1. PRINT THE LINE NUMBER. The message above named a property and nothing else -
#    no file, no line - so it could not be traced to a statement. The bash
#    counterpart reported "line 315" and was diagnosed in minutes.
# 2. EXIT NON-ZERO, so SSM reports Failed and the stage stops claiming success.
#
# Do not replace this with a try/catch around main(): a trap catches terminating
# errors raised anywhere, including inside functions called from functions, which
# is where this one came from.
trap {
    $inv = $_.InvocationInfo
    Write-Host ''
    Write-Host '  [FAIL] staging aborted on an unhandled error'
    Write-Host "         line    : $($inv.ScriptLineNumber)"
    Write-Host "         statement: $($inv.Line.Trim())"
    Write-Host "         message : $($_.Exception.Message)"
    Write-Host "         category: $($_.CategoryInfo.Category) / $($_.FullyQualifiedErrorId)"
    Write-Host ''
    Write-Host '  No manifest was written. Nothing on this host should be treated as staged.'
    exit 1
}

# Printed first, every run. Without it a stale fetch is invisible and a retest
# can silently re-run old code while looking like a fresh result.
$script:ScriptVersion = '2026-09-22.7-redis-databases-and-config-readback'

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

# RETRY, BECAUSE IMDS GOES AWAY FOR A WHILE ON THIS HOST AND COMES BACK.
#
# Build 78 failed here, and the host was healthy 20 minutes later - same
# instance, same role, `aws sts get-caller-identity` fine. The cause is the
# l2bridge network: Docker binds a vSwitch to the host NIC, the host address
# migrates to a vEthernet, and the link-local route to 169.254.169.254 is torn
# down and re-added around that. `route print` on the host afterwards showed the
# IMDS route present, On-link, and under "Persistent Routes: None" - so it is
# re-created at runtime, not pinned. Anything calling AWS inside that window
# gets no credentials at all.
#
# This is a RACE, so a bounded retry is the honest fix: if the profile is really
# absent it still fails, just 90 seconds later and having said what it tried.
# What it must never become is an unbounded wait that turns a missing instance
# profile into a hang.
#
# The durable fix belongs in the prereq script - re-assert the IMDS route after
# the Docker network is created, or pin it with `route ... -p`. Until that lands,
# this keeps staging off the critical path of a transient.
$identity   = $null
$maxTries   = 6
$delaySec   = 15
for ($try = 1; $try -le $maxTries; $try++) {
    $identity = Invoke-Aws @('sts','get-caller-identity','--query','Arn','--output','text') -AllowFailure
    if ($identity.ExitCode -eq 0) { break }
    if ($try -lt $maxTries) {
        Write-Warn "sts get-caller-identity failed (attempt $try of $maxTries). IMDS may be mid-reconfiguration from the container network; retrying in ${delaySec}s."
        Start-Sleep -Seconds $delaySec
    }
}
if ($identity.ExitCode -ne 0) {
    Write-Fail "aws sts get-caller-identity failed $maxTries times over $($maxTries * $delaySec)s. The instance profile is missing, or IMDS is unreachable."
    Write-Fail 'Check on the host: route print 169.254.169.254 should show an On-link route for it. If it is absent, the container network took it and did not put it back.'
    exit 1
}
if ($try -gt 1) { Write-Warn "identity resolved only on attempt $try - IMDS was briefly unavailable, which is the known l2bridge transition." }
Write-Ok "identity $($identity.Output)"

# EGRESS TO github.com, CHECKED ONCE, UP FRONT.
#
# Build 86 reported three separate component failures - one config clone and two
# 'unverified' verdicts - all of which were one fact: no route to github.com at
# that moment. One line here is worth three misleading ones later.
#
# Not fatal: the S3 work needs no GitHub access at all, and a flow whose configs
# all come from the daily snapshot can stage perfectly well without it.
$ghOk = $false
foreach ($try in 1..4) {
    $t = Test-NetConnection -ComputerName 'github.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue
    if ($t) { $ghOk = $true; break }
    if ($try -lt 4) {
        Write-Warn "github.com:443 not reachable (attempt $try of 4). The container network may still be settling; retrying in 15s."
        Start-Sleep -Seconds 15
    }
}
if ($ghOk) {
    Write-Ok 'github.com:443 reachable - the config repo can be read'
} else {
    Write-Warn 'github.com:443 NOT reachable from this host. Anything that needs the config repo will fail;'
    Write-Warn 'S3 artifacts are unaffected. Check the default route - creating the l2bridge vSwitches resets'
    Write-Warn 'the underlying adapters, and staging starts seconds after bootstrap.'
}

# ---------------------------------------------------------------------------
# GitHub token for the private config repo (configSource.gitRepo). Resolved by shape with the
# instance profile, the same way UserData resolves the bootstrap token, so there
# is one mechanism to understand and nothing lands in an argument list.
$script:GitHubToken = $null
function Resolve-GitHubToken {
    if ($script:GitHubToken) { return $true }
    if (-not $ConfigRepoTokenRef) { return $false }
    $raw = if ($ConfigRepoTokenRef.StartsWith('/')) {
        (Invoke-Aws @('ssm','get-parameter','--name',$ConfigRepoTokenRef,'--with-decryption',
                      '--query','Parameter.Value','--output','text') -AllowFailure).Output
    } else {
        (Invoke-Aws @('secretsmanager','get-secret-value','--secret-id',$ConfigRepoTokenRef,
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
        #
        # BASIC, NOT BEARER. Measured on 2026-09-10 against the private config
        # repo with a valid classic PAT:
        #   Authorization: Bearer <pat>  -> git ls-remote FAILED (401)
        #   Authorization: Basic  <b64>  -> git ls-remote OK
        # while the SAME token returned 200 from both api.github.com/user and the
        # repo's REST endpoint. api.github.com and the git transport are
        # different endpoints with different accepted schemes, so a REST probe
        # does NOT prove git will authenticate. x-access-token as the username
        # works for classic PATs, fine-grained PATs and App installation tokens
        # alike, so this survives a rotation to a different token type.
        $basic = [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes("x-access-token:$script:GitHubToken"))

        # THE HEADER GOES IN THE ENVIRONMENT, NOT ON THE COMMAND LINE.
        #
        # Build 82: the bash host cloned fine with `-c "http.extraheader=..."`
        # and this host failed three times with `git exit 128`. The difference is
        # PowerShell 5.1's native-argument handling - the value contains SPACES
        # ("Authorization: Basic <b64>") and PowerShell re-splits it when handing
        # it to a native executable, so git received a truncated -c value and a
        # pair of stray arguments. The project's trap list already carries
        # "command-line quoting is silently rewritten in two different places";
        # this is a third.
        #
        # GIT_CONFIG_COUNT/KEY/VALUE (git >= 2.31) sets the same config with no
        # argument parsing at all, and it applies to EVERY git process in this
        # scope - which the clone and the sparse-checkout both need. It also keeps
        # the token out of the process command line, where `ps`-equivalents can
        # read it.
        #
        # Verify git is new enough rather than assuming: on an older git these
        # variables are IGNORED, which would look exactly like a rejected token.
        $gitVer = (& git --version) -replace '[^0-9.]', ''
        $verParts = @($gitVer -split '\.' | Where-Object { $_ -ne '' })
        $verOk = $verParts.Count -ge 2 -and
                 ([int]$verParts[0] -gt 2 -or ([int]$verParts[0] -eq 2 -and [int]$verParts[1] -ge 31))
        if (-not $verOk) {
            Write-Warn "git $gitVer is older than 2.31, which ignores GIT_CONFIG_COUNT. The config-repo clone will not authenticate; upgrade git on this host."
        }
        # ONE ENTRY, AND credential.helper STAYS ON THE COMMAND LINE.
        #
        # Build 84:
        #   git: error: missing config value GIT_CONFIG_VALUE_0
        #   git: fatal: unable to parse command-line config
        #
        # ASSIGNING '' TO $env:X IN POWERSHELL DELETES THE VARIABLE. It does not
        # set it to an empty string. So `$env:GIT_CONFIG_VALUE_0 = ''` - meant to
        # express `credential.helper=` with an empty value - removed VALUE_0
        # entirely, git saw COUNT=2 with KEY_0 and no VALUE_0, and refused to
        # parse ANY of the config. That killed the http.extraheader entry too,
        # which was correct, so the symptom was a generic exit 128 with the
        # header never applied.
        #
        # The split below is deliberate:
        #   http.extraheader -> ENVIRONMENT. Its value contains spaces, and
        #       PowerShell 5.1 re-splits native command arguments on spaces
        #       (build 82's original exit 128).
        #   credential.helper= -> COMMAND LINE. It has no spaces, so PowerShell
        #       cannot mangle it, and an empty config value is expressible there
        #       where the environment form cannot express it at all.
        $env:GIT_CONFIG_COUNT = '1'
        $env:GIT_CONFIG_KEY_0 = 'http.extraheader'
        $env:GIT_CONFIG_VALUE_0 = "Authorization: Basic $basic"
        # GIT_TERMINAL_PROMPT=0: on a 401 git otherwise falls back to asking for a
        # username, and on a headless host that surfaces as "could not read
        # Username for 'https://github.com'" - a message about the fallback, not
        # about the rejection.
        # CHECK OUT THE REPO AS IT STOOD ON THE MARKET DATE, NOT AT TODAY'S HEAD.
        #
        # Dev, 2026-09-17: "it is possible that the config that was pushed on git
        # around 1 year ago is still being used."
        #
        # Which is the reason to ask git for a DATE instead of judging a backup
        # by its age. A config untouched for a year is identical on every date in
        # that year. What invalidates a replay is a config changed AFTER the
        # market date - and cloning HEAD imports exactly that with no way to see
        # it. --depth 1 is gone because rev-list cannot walk unfetched history;
        # --filter=blob:none keeps it cheap.
        $env:GIT_TERMINAL_PROMPT = '0'
        $clone = Invoke-GitNet -GitArgs @(
            '-c', 'credential.helper=',
            'clone', '--quiet', '--branch', $Branch, '--filter=blob:none', '--sparse', '--no-checkout',
            "https://github.com/$Owner/$Repo.git", "$work\repo")
        $cloneOut = $clone.Output
        if ($clone.ExitCode -ne 0) {
            Write-Warn "clone of $Repo@$Branch failed after $($clone.Attempts) attempt(s) (git exit $($clone.ExitCode)). The path in the repo has NOT been checked - do not read this as a missing folder."
            # PRINT WHAT GIT SAID. Build 82 reported only "git exit 128" three
            # times, which is git's generic fatal and says nothing about whether
            # the cause was auth, a bad ref or the URL.
            if ($cloneOut) { $cloneOut | ForEach-Object { Write-Warn "  git: $_" } }
            return $null
        }
        Push-Location "$work\repo"
        # DO NOT DISCARD THIS OUTPUT SILENTLY. A sparse-checkout that matches
        # nothing leaves an empty tree, and the caller then reports the path as
        # absent from the repo - which is how build 79 blamed the config repo for
        # a path that exists on main.
        try {
            # ISO 'T' SEPARATOR, NOT A SPACE. Build 85:
            #   [warn] no commit on origin/main at or before 2026-09-10
            # after a clone that had succeeded. `--before="2026-09-10 23:59:59"`
            # contains a space, PowerShell 5.1 re-split it, and git received
            # `23:59:59` as a separate argument - so rev-list failed and returned
            # nothing. Same trap as the extraheader value in build 82 and the
            # third time it has bitten in this file. git's approxidate accepts
            # the T form, which has no space to split on.
            #
            # 23:59:59 so a commit made ON the market date counts as in force.
            # CAPTURE FIRST, FILTER SECOND. This was
            #     $asof = (& git rev-list ... 2>&1 | Select-Object -First 1)
            # and `-First 1` stops the pipeline as soon as it has its object,
            # which terminates git mid-write and leaves $LASTEXITCODE non-zero
            # for a command that had already printed the right answer. The
            # failure branch then fired on a successful query.
            $revOut = @(& git rev-list -1 "--before=$($plan.marketDate)T23:59:59" "origin/$Branch" 2>&1)
            $revRc  = $LASTEXITCODE
            $asof   = @($revOut | Where-Object { "$_" -match '^[0-9a-f]{7,40}$' })[0]

            # THREE DIFFERENT FACTS, THREE DIFFERENT MESSAGES. One message used
            # to cover all of them, and it asserted a cause: "the branch may be
            # younger than the market date". On build 91 that line appeared on
            # the Windows host while the Linux host resolved the very same
            # branch to a commit dated on the market date - so the message was
            # not merely unhelpful, it was false, and it pointed the next
            # reader at the repo instead of at this code.
            if ($revRc -ne 0) {
                Write-Warn "the as-of-market-date query failed (git exit $revRc). This says nothing about whether such a commit exists."
                $revOut | ForEach-Object { Write-Warn "  git: $_" }
                return $null
            }
            if (-not $asof) {
                Write-Warn "git found no commit on origin/$Branch at or before $($plan.marketDate). The query ran and returned nothing, so the branch really may be younger than the market date."
                return $null
            }
            $script:GitAsOfSha = $asof
            $dateOut = @(& git log -1 --format=%cI $asof 2>&1)
            $script:GitAsOfDate = if ($LASTEXITCODE -eq 0) { @($dateOut)[0] } else { $null }
            # Commits to this path AFTER the market date. Zero means the config
            # has not changed since, so this version is also the current one -
            # which is the direct answer to "is a year-old config still right?".
            # NO LEADING SLASH. gitPath is stored with a leading backslash, so
            # the naive replace yields "/NY4 Primary Servers/...", and git
            # rejects an absolute pathspec: "fatal: Invalid path ... exit 128".
            # Verified in a scratch repo on 2026-09-21, worktree and bare alike.
            $pathspec = $Path.Replace('\', '/').TrimStart('/')
            $after = @(& git log --oneline "$asof..origin/$Branch" -- $pathspec 2>&1)
            if ($LASTEXITCODE -ne 0) {
                # EMPTY OUTPUT FROM A FAILED COMMAND IS NOT "no commits".
                # Treating it as zero is how a broken query becomes evidence.
                Write-Warn "could not count commits after the market date (git exit $LASTEXITCODE); reporting it as unknown rather than as zero."
                $script:GitAfterCount = $null
                $script:GitAfterLog = @()
            }
            else {
                $script:GitAfterCount = $after.Count
                $script:GitAfterLog = $after
            }
            # The header goes on THIS call too. `git -c ...` configures one git
            # process, and --filter=blob:none defers blob download, so the fetch
            # happens here in a separate process. Build 81 failed exactly this
            # way on the Linux host after a clone that had succeeded.
            # Same GIT_CONFIG_* environment as the clone - it is still in scope,
            # so this process authenticates too. --filter=blob:none defers the
            # blob download to here, which is why it needs to.
            $sparse = & git sparse-checkout set --no-cone $Path.Replace('\', '/') 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "sparse-checkout failed for '$Path' (git exit $LASTEXITCODE): $sparse"
                Write-Warn 'The repo path has NOT been checked - do not read the next warning as a missing folder.'
                return $null
            }
            # Materialise the market-date commit. Blobs are fetched here, so the
            # GIT_CONFIG_* credentials still in scope are what make it possible.
            $co = & git checkout --quiet $asof 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warn "checkout of $asof (as of $($plan.marketDate)) failed: $co"
                return $null
            }
            Write-Ok "using $($asof.Substring(0,8)) committed $script:GitAsOfDate - the version in force on $($plan.marketDate)"
            if ($null -eq $script:GitAfterCount) {
                Write-Warn "whether this path changed after $($plan.marketDate) is UNKNOWN - the history query failed. The staged version is still the market-date one."
            }
            elseif ($script:GitAfterCount -eq 0) {
                Write-Ok "unchanged since (0 commits to this path after $($plan.marketDate)), so this is also the current config"
            }
            else {
                Write-Warn "this path has $($script:GitAfterCount) commit(s) AFTER $($plan.marketDate). Staging the market-date version, not HEAD - HEAD would replay configuration the session never ran under."
                $script:GitAfterLog | ForEach-Object { Write-Warn "    $_" }
            }
        }
        finally { Pop-Location }
    }
    finally {
        $ErrorActionPreference = $previous
        # Clear the token out of the environment as soon as git is done with it.
        # It would otherwise be inherited by every later child process in this
        # script, including the AWS CLI.
        Remove-Item Env:GIT_CONFIG_COUNT, Env:GIT_CONFIG_KEY_0, Env:GIT_CONFIG_VALUE_0 `
                    -ErrorAction SilentlyContinue
    }

    # The files may be one level down, in config\. The repo convention puts them
    # under <host>\<engine>\config while the plan's gitPath names <engine>. Try
    # the declared path, then its config\ child, and SAY which was used - a
    # silent guess is how the wrong layout gets baked in. Mirrors the bash side.
    $resolved = Join-Path "$work\repo" $Path.TrimStart('\')
    if ((Test-Path -LiteralPath $resolved) -and
        @(Get-ChildItem -LiteralPath $resolved -File -ErrorAction SilentlyContinue).Count -gt 0) {
        return $resolved
    }
    $nested = Join-Path $resolved 'config'
    if ((Test-Path -LiteralPath $nested) -and
        @(Get-ChildItem -LiteralPath $nested -File -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Warn "no files directly in '$Path'; using its config\ subfolder. If that is the repo convention, put it in the plan's gitPath instead of relying on this fallback."
        return $nested
    }
    return $null
}

# Did this component's configuration change between the snapshot date and the
# market date? Answered from the config repo's history - the only record of WHEN
# a config changed. The S3 snapshot job only records that it ran.
#
# Returns 'changed' | 'unchanged' | $null. $null means it COULD NOT ANSWER (no
# token, no gitPath, clone failed) and is deliberately not folded into either
# verdict - the point is to stop assuming.
$script:ConfigChangeCount = 0
$script:ConfigChangeNote = ''
# Run a git command that talks to the network, retrying ONLY on a connection
# failure.
#
# Build 86:
#   fatal: unable to access the config repo over https:
#   Failed to connect to github.com:443 after 21049 ms: Could not connect to server
#
# Checked on the host minutes later: Test-NetConnection github.com -Port 443
# succeeded, one clean default route via the management NIC. So egress WORKS on
# that host - it was not available at the moment staging ran. Build 85's clone of
# the same repo succeeded, which is what makes it intermittent rather than
# broken.
#
# The likely cause is the same transition that took IMDS away in build 80:
# Docker's l2bridge networks put a vSwitch on each prod NIC (vEthernet
# (Ethernet 2) and vEthernet (Ethernet 4) are visible on the host), creating a
# vSwitch resets the underlying adapter, and staging starts seconds after
# bootstrap finishes.
#
# RETRY ONLY THE NETWORK CASE. A 401, a missing branch or a bad path will fail
# identically on every attempt, and retrying those turns a clear two-second
# failure into a slow one - which is how build 79 spent 27 minutes.
$script:GIT_NET_PATTERNS = @(
    'Could not connect to server', 'Failed to connect to',
    'Could not resolve host', 'Operation timed out',
    'Connection timed out', 'unable to access'
)
function Invoke-GitNet {
    param(
        [Parameter(Mandatory)][string[]] $GitArgs,
        [int] $MaxTries = 4,
        [int] $DelaySeconds = 15
    )
    for ($try = 1; $try -le $MaxTries; $try++) {
        $out = & git @GitArgs 2>&1
        $rc = $LASTEXITCODE
        if ($rc -eq 0) {
            if ($try -gt 1) { Write-Warn "git succeeded on attempt $try - egress was not ready at first" }
            return [pscustomobject]@{ ExitCode = 0; Output = $out; Attempts = $try }
        }
        $text = ($out | Out-String)
        $isNetwork = $false
        foreach ($p in $script:GIT_NET_PATTERNS) { if ($text -match [regex]::Escape($p)) { $isNetwork = $true; break } }
        if (-not $isNetwork -or $try -eq $MaxTries) {
            return [pscustomobject]@{ ExitCode = $rc; Output = $out; Attempts = $try }
        }
        Write-Warn "git could not reach the remote (attempt $try of $MaxTries). Retrying in ${DelaySeconds}s - the container network may still be settling."
        Start-Sleep -Seconds $DelaySeconds
    }
}

function Test-ConfigChangedBetween {
    param($ConfigSource, [int] $Offset)
    $script:ConfigChangeCount = 0
    $script:ConfigChangeNote = ''

    $gp = $ConfigSource.gitPath
    $repo = $ConfigSource.gitRepo
    $branch = if ($ConfigSource.gitBranch) { $ConfigSource.gitBranch } else { 'main' }
    if (-not $gp -or -not $repo) {
        $script:ConfigChangeNote = 'no gitPath/gitRepo declared for this component, so the config repo cannot be consulted'
        return $null
    }
    if (-not (Resolve-GitHubToken)) {
        $script:ConfigChangeNote = 'no usable config-repo token, so the config repo cannot be consulted'
        return $null
    }

    $since = ([datetime]::ParseExact($plan.marketDate, 'yyyy-MM-dd', $null)).AddDays($Offset).ToString('yyyy-MM-dd')
    $work = Join-Path $env:TEMP ("hist-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $basic = [Convert]::ToBase64String(
            [Text.Encoding]::ASCII.GetBytes("x-access-token:$script:GitHubToken"))
        # Environment, not the command line - same PowerShell native-argument
        # quoting problem that produced git exit 128 in build 82.
        # One entry only - see the note in Get-GitFolder. Assigning '' to an
        # $env: variable DELETES it, so a COUNT that promises an empty value git
        # can never find makes git reject the whole config. credential.helper=
        # goes on the command line, where an empty value is expressible and
        # where PowerShell cannot re-split it (no spaces).
        $env:GIT_CONFIG_COUNT = '1'
        $env:GIT_CONFIG_KEY_0 = 'http.extraheader'
        $env:GIT_CONFIG_VALUE_0 = "Authorization: Basic $basic"
        $env:GIT_TERMINAL_PROMPT = '0'
        # Commit graph only: no blobs, no working tree. This is a history query.
        # Same retry as Get-GitFolder: this clone hit the identical transient
        # egress failure in build 86, and the result was an 'unverified' verdict
        # on a config that could have been verified.
        $hist = Invoke-GitNet -GitArgs @(
            '-c', 'credential.helper=',
            'clone', '--quiet', '--bare', '--filter=blob:none', '--branch', $branch,
            "https://github.com/$($plan.engineRepoOwner)/$repo.git", "$work\hist")
        if ($hist.ExitCode -ne 0) {
            # Say WHY, rather than only that it could not be read. The
            # distinction between "no egress" and "rejected" decides who fixes it.
            $why = ($hist.Output | Out-String).Trim() -split "`n" | Select-Object -Last 1
            $script:ConfigChangeNote = "the config repo could not be read to check for changes: $why"
            Write-Warn "config-repo history clone failed after $($hist.Attempts) attempt(s): $why"
            return $null
        }
        Push-Location "$work\hist"
        try {
            # ISO 'T' SEPARATOR, AND THE EXIT CODE IS CHECKED.
            #
            # Build 85 reported "stale-but-unchanged" for both OMS engines with
            # the evidence "no commits between 2026-07-10 and 2026-09-10" - and
            # that verdict was NOT EVIDENCE. `--since="2026-07-10 00:00:00"`
            # contains a space, PowerShell re-split it, git got a stray
            # `00:00:00` argument, and the query returned nothing. Empty output
            # from a broken command was then read as "no commits found".
            #
            # A false "unchanged" is the worst outcome this function can produce:
            # it converts an unknown into a positive assurance that the staged
            # config matched the market date. So the date loses its space, and a
            # non-zero exit now returns UNKNOWN instead of a verdict.
            # Leading slash stripped - see the note in Get-GitFolder. This is
            # the call that returned "git exit 128" on build 91 for both OMS
            # engines, which is why both were recorded 'unverified'.
            $betweenPath = $gp.Replace('\', '/').TrimStart('/')
            $between = @(& git log --oneline "--since=${since}T00:00:00" `
                             "--until=$($plan.marketDate)T23:59:59" `
                             -- $betweenPath 2>&1)
            $logRc = $LASTEXITCODE
        }
        finally { Pop-Location }
        if ($logRc -ne 0) {
            $script:ConfigChangeNote = "the config-repo history query failed (git exit $logRc), so whether the config changed is unknown"
            return $null
        }
        $script:ConfigChangeCount = $between.Count
        if ($between.Count -gt 0) {
            $between | ForEach-Object { Write-Warn "    $_" }
            $script:ConfigChangeNote = "$($between.Count) commit(s) to $gp between $since and $($plan.marketDate)"
            return 'changed'
        }
        $script:ConfigChangeNote = "no commits to $gp between $since and $($plan.marketDate)"
        return 'unchanged'
    }
    finally {
        $ErrorActionPreference = $previous
        Remove-Item Env:GIT_CONFIG_COUNT, Env:GIT_CONFIG_KEY_0, Env:GIT_CONFIG_VALUE_0 `
                    -ErrorAction SilentlyContinue
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
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
            # A STALE SNAPSHOT IS NOT AUTOMATICALLY A WRONG CONFIG.
            #
            # An earlier version refused any snapshot outside the window. Dev,
            # 2026-09-17: "it is possible that the config that was pushed on git
            # around 1 year ago is still being used." If the config has not
            # changed, a July snapshot IS the September config and refusing it
            # blocks a run for nothing.
            #
            # The backup's age is not the question. Whether the configuration
            # CHANGED in between is, and only the config repo can answer that.
            # Verdicts: within-window / stale-but-unchanged / unverified, or a
            # hard failure when the repo shows a real change in between.
            #
            # Still the reason this exists: builds 81 and 82 staged a 62-day-old
            # snapshot as plain 'staged', the gap recorded only as a number.
            $offAbs = [math]::Abs($resolved.Offset)
            $snapVerdict = 'within-window'
            $snapEvidence = ''
            if ($offAbs -gt $ArchiveWindowDays) {
                Write-Warn "${Name}: snapshot $($resolved.Key) is $offAbs day(s) from the market date $($plan.marketDate) - outside the $ArchiveWindowDays-day window."
                Write-Warn "${Name}: checking the config repo for changes in between, because a backup gap and a config change are not the same thing."
                $verdict = Test-ConfigChangedBetween -ConfigSource $cs -Offset $resolved.Offset
                $snapEvidence = $script:ConfigChangeNote
                if ($verdict -eq 'changed') {
                    Write-Fail "${Name}: the config repo has $($script:ConfigChangeCount) commit(s) to this path between the snapshot and $($plan.marketDate)."
                    Write-Fail "${Name}: REFUSING to stage. This snapshot predates a real configuration change, so it is not what the session ran under."
                    Add-Result $Name 'config' 'failed' @{
                        source = 's3-daily-snapshot'; key = $resolved.Key
                        dateOffsetDays = $resolved.Offset; windowDays = $ArchiveWindowDays
                        marketDate = $plan.marketDate; files = 0
                        commitsBetweenSnapshotAndMarketDate = $script:ConfigChangeCount
                        reason = 'snapshot is outside the window AND the config repo shows changes in between, so it is not the configuration in force on the market date' }
                    return
                }
                elseif ($verdict -eq 'unchanged') {
                    Write-Ok "${Name}: the config repo shows NO changes to this path between $($resolved.Key) and $($plan.marketDate) - the snapshot is stale but the configuration is not."
                    $snapVerdict = 'stale-but-unchanged'
                }
                else {
                    Write-Warn "${Name}: could not check the config repo, so whether the config changed in between is UNKNOWN."
                    Write-Warn "${Name}: staging and recording it as unverified. Do not read a green run as evidence the configuration matched."
                    $snapVerdict = 'unverified'
                }
            }
            Write-Ok "${Name}: snapshot $($resolved.Key) (offset $($resolved.Offset)d from $($plan.marketDate), $snapVerdict)"
            # Both initialised BEFORE the branch: under Set-StrictMode a
            # variable that only exists on one path throws on the other, and
            # the dry-run path never enters the copy below.
            $files = 0
            $subdirs = 0
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
            # marketDateVerdict is the field to read, not dateOffsetDays. The
            # offset alone is what let a 62-day-old snapshot pass as plain
            # 'staged': a number with no judgement attached.
            Add-Result $Name 'config' 'staged' @{
                source = 's3-daily-snapshot'; key = $resolved.Key
                dateOffsetDays = $resolved.Offset; files = $files; dest = $dest
                marketDate = $plan.marketDate; windowDays = $ArchiveWindowDays
                marketDateVerdict = $snapVerdict; marketDateEvidence = $snapEvidence }
            Test-AgainstGit -Name $Name -ConfigSource $cs -Dest $dest
        }

        'git-serverconfigs' {
            if (-not (Resolve-GitHubToken)) {
                Write-Warn "${Name}: config lives in the private $($cs.gitRepo) repo and no usable -ConfigRepoTokenRef was given"
                Add-Result $Name 'config' 'skipped' @{
                    reason = 'private repo and no GitHub token reference supplied'
                    repo = $cs.gitRepo; path = $cs.gitPath }
                return
            }
            # "fetching", not Write-Ok: this announces intent. It printed [ok]
            # here and a contradicting [warn] two lines later, which reads as a
            # step that passed and was then overruled.
            Write-Host "  [ .. ] ${Name}: fetching $($cs.gitRepo)@$($cs.gitBranch) at $($cs.gitPath)" -ForegroundColor Cyan
            $files = 0
            if (-not $DryRun) {
                # THREE OUTCOMES, NOT ONE MESSAGE. This said
                #   "<path> not present in <repo>@<branch>, or the clone failed"
                # for every failure, so a rejected token, a bad branch and a
                # genuinely absent folder were indistinguishable. Build 79 proved
                # the cost on the bash side: the path DOES exist on main, and the
                # message sent everyone to the repo instead of to git auth.
                # Get-GitFolder now warns on a non-zero git exit, so a clone
                # failure has already been reported by the time we get here.
                $src = Get-GitFolder -Owner $plan.engineRepoOwner -Repo $cs.gitRepo `
                                     -Branch $cs.gitBranch -Path $cs.gitPath
                if (-not $src) {
                    Write-Warn "${Name}: no files for $($cs.gitPath) in $($cs.gitRepo)@$($cs.gitBranch)."
                    Write-Warn "${Name}: if a clone failure was reported above, the repo path has NOT been checked - fix that first rather than editing the path."
                    Add-Result $Name 'config' 'failed' @{
                        reason = 'git checkout produced nothing - clone failure or absent path; see the warnings above'
                        repo = $cs.gitRepo; branch = $cs.gitBranch; path = $cs.gitPath }
                    return
                }
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
                # COPY THE TREE, PRESERVING STRUCTURE.
                #
                # This took depth 1 only. The reasoning - do not FLATTEN
                # sub-folders into the root, because two same-named files in
                # different folders would overwrite each other - was right, but
                # it was implemented as "do not copy them at all", which is a
                # different thing.
                #
                # The Linux hub proved the cost on 2026-09-22: its acceptor.cfg
                # references ./config/SSL/pem/cert.pem, that subtree was never
                # staged, the manifest counted the root files and said "staged",
                # and the engine failed with "file could not be opened" only
                # after the config was finally delivered to the right directory.
                #
                # Copying the CONTENTS recursively keeps root files at the root
                # and subtrees at their own depth, so relative paths inside the
                # configs resolve exactly as they do in production.
                Copy-Item -Path (Join-Path $src '*') -Destination $dest -Recurse -Force
                # Counted over the TREE. A top-level count would under-report
                # precisely the files whose absence caused that failure.
                $files = @(Get-ChildItem -LiteralPath $dest -File -Recurse).Count
                $subdirs = @(Get-ChildItem -LiteralPath $dest -Directory -Recurse).Count
            }
            Add-Result $Name 'config' 'staged' @{
                source = 'git-serverconfigs'; repo = $cs.gitRepo; branch = $cs.gitBranch
                path = $cs.gitPath; files = $files; subdirectories = $subdirs; dest = $dest
                marketDate = $plan.marketDate
                commit = $script:GitAsOfSha; commitDate = $script:GitAsOfDate
                commitsAfterMarketDate = $script:GitAfterCount
                unchangedSinceMarketDate = ($script:GitAfterCount -eq 0)
                resolution = 'the last commit at or before the market date, not branch HEAD' }
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
    # Empty-safe for the same reason as the artifacts loop below: if $archive has
    # no properties at all, .PSObject.Properties is an empty collection and
    # member-enumerating .Name off it throws under StrictMode instead of
    # returning nothing. -contains on @() is simply false.
    $archiveProps = @()
    if ($archive) {
        $p = $archive.PSObject.Properties
        if ($p) { $archiveProps = @($p | ForEach-Object { $_.Name }) }
    }
    if ($archiveProps -contains 'fixArchive' -and $archive.fixArchive) {
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
            # THE COPY'S EXIT CODE DECIDES THE STATUS. This used to record
            # 'staged' unconditionally, one line after warning that the fetch had
            # failed. The bash counterpart did the same and build 76 reported
            # "staged: 3" for a host where all three fetches failed with
            # AccessDenied - and environment.json repeated it, because the
            # manifest is what it reads.
            $fixRc = 0
            $fixReason = ''
            $foldersTaken = @()
            if (-not $DryRun) {
                New-Item -ItemType Directory -Path (Join-Path $dest 'fix') -Force | Out-Null

                # ONE WINDOW OF DATED FOLDERS, NOT THE WHOLE PREFIX.
                #
                # This was a flat `aws s3 cp --recursive` over the entire prefix,
                # and THIS HOST is where that hurt: build 79 spent 27 of its 28
                # minutes inside this single call, pulling FIX logs from 2024 and
                # 2025 that no 2026 replay will read.
                #
                # Selection is on the dated FOLDER NAME, not LastModified:
                # LastModified is upload time, so a restored or re-uploaded object
                # reports today and a modified-time window would skip the very
                # file that was asked for.
                #
                # A window rather than one computed folder, because the folder is
                # not the market date - the backup job writes the following
                # morning, and that offset is not consistent between engines.
                # Mirrors 04-stage-artifacts.sh; keep the two in step.
                $listed = Invoke-Aws @('s3api','list-objects-v2',
                                       '--bucket', $fa.bucket,
                                       '--prefix', ($fa.prefix.TrimEnd('/') + '/'),
                                       '--delimiter', '/',
                                       '--query', 'CommonPrefixes[].Prefix',
                                       '--output', 'text') -AllowFailure

                $mkt = [datetime]::ParseExact($plan.marketDate, 'yyyy-MM-dd', $null)
                if ($listed.ExitCode -eq 0 -and $listed.Output) {
                    $rows = @($listed.Output -split '\s+' | Where-Object { $_ })

                    # INFER THE CONVENTION FROM THE LISTING, DO NOT ASSUME IT.
                    # Two formats are in use in the same bucket on different
                    # prefixes - build 81 saw YYYY-MM-DD under this host's FIX
                    # prefix and DD-MM-YYYY under the Linux host's. And DD-MM vs
                    # MM-DD is ambiguous whenever both numbers are <= 12.
                    # Any leaf with a component > 12 can only be read one way,
                    # and those settle it for the whole prefix. Mirrors the bash
                    # side; keep the two in step.
                    $dmy = 0; $mdy = 0
                    foreach ($raw in $rows) {
                        $leaf = $raw.TrimEnd('/').Split('/')[-1]
                        if ($leaf -match '^(\d{2})-(\d{2})-(\d{4})$') {
                            $a = [int]$Matches[1]; $b = [int]$Matches[2]
                            if ($a -gt 12 -and $b -le 12) { $dmy++ }
                            elseif ($b -gt 12 -and $a -le 12) { $mdy++ }
                        }
                    }
                    $formats = @('yyyy-MM-dd')
                    if ($dmy -gt $mdy)      { $formats += 'dd-MM-yyyy' }
                    elseif ($mdy -gt $dmy)  { $formats += 'MM-dd-yyyy' }
                    else {
                        $formats += @('dd-MM-yyyy','MM-dd-yyyy')
                        Write-Warn "${Name}: could not infer the dated-folder format from this prefix (no folder with a component > 12); accepting both DD-MM and MM-DD, which may take an extra folder"
                    }

                    foreach ($raw in $rows) {
                        $leaf = $raw.TrimEnd('/').Split('/')[-1]
                        foreach ($fmt in $formats) {
                            $parsed = [datetime]::MinValue
                            if ([datetime]::TryParseExact($leaf, $fmt, $null,
                                    [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                                if ([math]::Abs(($parsed - $mkt).Days) -le $ArchiveWindowDays) {
                                    $foldersTaken += $raw
                                    break
                                }
                            }
                        }
                    }
                }

                if ($foldersTaken.Count -eq 0) {
                    Write-Warn "${Name}: no dated folder within $ArchiveWindowDays day(s) of $($plan.marketDate) under $($fa.prefix)/."
                    Write-Warn "${Name}: NOT falling back to the whole prefix - that is years of data. Raise -ArchiveWindowDays if the backup offset is larger than expected."
                    $fixRc = 1
                    $fixReason = "no dated folder within $ArchiveWindowDays days of the market date"
                }
                else {
                    Write-Ok "${Name}: $($foldersTaken.Count) dated folder(s) within $ArchiveWindowDays day(s) of $($plan.marketDate)"
                    foreach ($p in $foldersTaken) {
                        $leaf = $p.TrimEnd('/').Split('/')[-1]
                        Write-Host "           $leaf"
                        $copy = Invoke-Aws @('s3','cp',"s3://$($fa.bucket)/$p",
                                             (Join-Path $dest "fix\$leaf\"),
                                             '--recursive','--only-show-errors') -AllowFailure
                        if ($copy.ExitCode -ne 0) {
                            $fixRc = $copy.ExitCode
                            # DISTINGUISH ARCHIVED FROM FORBIDDEN, as the bash
                            # side does. InvalidObjectState is Glacier or
                            # Intelligent-Tiering archive access - not a
                            # permission problem, and blaming the prefix or the
                            # role sends the reader to the wrong place entirely.
                            if ($copy.Output -match 'InvalidObjectState') {
                                $fixReason = 'objects in an archived S3 access tier; restore required'
                            }
                        }
                    }
                    if ($fixRc -ne 0) {
                        if ($fixReason -like 'objects in an archived*') {
                            Write-Warn "${Name}: the FIX objects are ARCHIVED (S3 Glacier / Intelligent-Tiering archive tier), not missing and not forbidden."
                            Write-Warn "${Name}: they must be restored before they can be read - aws s3api restore-object - and a restore takes minutes to hours depending on tier."
                        }
                        else {
                            Write-Warn "${Name}: FIX message fetch failed (exit $fixRc; prefix may not exist, or the host role lacks s3:ListBucket on the BUCKET arn as well as /*)"
                            $fixReason = "aws s3 cp exited $fixRc"
                        }
                    }
                }
            }
            # foldersTaken goes in the manifest so the backup-offset convention
            # can be read off a real run rather than asserted.
            $leaves = @($foldersTaken | ForEach-Object { $_.TrimEnd('/').Split('/')[-1] })
            if ($fixRc -eq 0) {
                Add-Result $Name 'fixArchive' 'staged' @{
                    bucket = $fa.bucket; prefix = $fa.prefix
                    marketDate = $plan.marketDate; windowDays = $ArchiveWindowDays
                    foldersTaken = $leaves }
            }
            else {
                Add-Result $Name 'fixArchive' 'failed' @{
                    marketDate = $plan.marketDate; windowDays = $ArchiveWindowDays
                    foldersTaken = $leaves
                    bucket = $fa.bucket; prefix = $fa.prefix
                    reason = if ($fixReason) { $fixReason } else { "aws s3 cp exited $fixRc" } }
            }
        }
    }

    # DO NOT member-enumerate .Name off .PSObject.Properties.
    #
    # This was:
    #     if (-not $archive.artifacts) { return }
    #     foreach ($family in $archive.artifacts.PSObject.Properties.Name) {
    # and it is what aborted Windows staging in builds 76, 78 and 79 with
    #     The property 'Name' cannot be found on this object.
    #     FullyQualifiedErrorId : PropertyNotFoundStrict
    #
    # A component in one of the flows declares logArchive.artifacts as an EMPTY
    # object. An empty PSCustomObject is truthy, so the -not guard let it
    # through; then
    # .PSObject.Properties is an empty collection, and under
    # Set-StrictMode -Version Latest, member-enumerating .Name off an empty
    # collection throws rather than yielding nothing.
    #
    # Same shape as $distinct.Count in verify-all.ps1: a member access that works
    # on one-or-more and throws on zero. Piping to ForEach-Object never
    # member-enumerates, so it is empty-safe; @() makes .Count always exist.
    $families = @()
    if ($archive.artifacts) {
        $props = $archive.artifacts.PSObject.Properties
        if ($props) { $families = @($props | ForEach-Object { $_.Name }) }
    }
    if ($families.Count -eq 0) { return }
    foreach ($family in $families) {
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
        # Same coherence window as the config snapshot, for the same reason: an
        # AsynchDB set or a rotated log from a different month is not the state
        # the market date started from. Build 82 staged AsynchDB files 63 days
        # old and called them staged.
        $famAbs = [math]::Abs($resolved.Offset)
        if ($famAbs -gt $ArchiveWindowDays) {
            if ($spec.optional) {
                Write-Skip "$Name/${family}: nearest entry is ${famAbs}d from $($plan.marketDate) (outside ${ArchiveWindowDays}d) - not staged (optional)"
                Add-Result $Name $family 'skipped' @{
                    key = $resolved.Key; dateOffsetDays = $resolved.Offset
                    windowDays = $ArchiveWindowDays; optional = $true
                    reason = 'nearest dated entry is outside the market-date window' }
            }
            else {
                Write-Fail "$Name/${family}: nearest entry $($resolved.Key) is ${famAbs}d from the market date $($plan.marketDate) - outside the $ArchiveWindowDays-day window. REFUSING to stage."
                Add-Result $Name $family 'failed' @{
                    key = $resolved.Key; dateOffsetDays = $resolved.Offset
                    windowDays = $ArchiveWindowDays; optional = $false
                    reason = 'nearest dated entry is outside the market-date window; refused rather than staged' }
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
# ENGINE CONFIGS: this host's own components only. The engine resolves its config
# relative to its own working directory, so it has to be on the machine running
# the engine.
Write-Step 'Staging engine configs'
$components = @($plan.groups | ForEach-Object { $_.services } | ForEach-Object { $_.containerName })
if ($components.Count -eq 0) { Write-Warn 'this host runs no components; no engine configs to stage' }

foreach ($name in $components) {
    if ($Only -and $name -ne $Only) { continue }
    $service = @($plan.groups | ForEach-Object { $_.services } | Where-Object { $_.containerName -eq $name })[0]
    Write-Host "`n  $name" -ForegroundColor Cyan
    Stage-Config -Name $name -Service $service
}

# CAPTURES: every component in the flow, on the nominated capture host only.
#
# Dev, 2026-09-17: the FIX messages, Quill logs and the rest are read by
# FixToFixTestingApp, which runs on THIS host. Staging each capture beside the
# engine that produced it left half the corpus on the Linux host in build 82,
# where the driver will never open it.
#
# An EMPTY captures list is a legitimate "not this host". A MISSING key means the
# plan predates the split, and silently staging nothing would be the worst
# outcome - so the two are distinguished.
$planProps = @()
if ($plan) {
    $pp = $plan.PSObject.Properties
    if ($pp) { $planProps = @($pp | ForEach-Object { $_.Name }) }
}
if ($planProps -notcontains 'captures') {
    Write-Fail 'this plan has no "captures" key - it was generated before captures moved to one host.'
    Write-Fail 'Regenerate it. Staging from the old per-host layout puts captures where the replay driver cannot read them.'
    exit 1
}

$captures = @($plan.captures)
if ($SkipCaptures) {
    Write-Step 'Captures'
    Write-Skip 'captures (-SkipCaptures)'
}
elseif ($captures.Count -eq 0) {
    Write-Step 'Captures'
    Write-Skip $plan.capturesNote
}
else {
    Write-Step "Staging captures for the whole flow ($($captures.Count) component(s))"
    Write-Ok $plan.capturesNote
    foreach ($cap in $captures) {
        if ($Only -and $cap.component -ne $Only) { continue }
        Write-Host "`n  $($cap.component)" -ForegroundColor Cyan -NoNewline
        Write-Host "  ($($cap.runsOnRole) engine on $($cap.prodHost))" -ForegroundColor DarkGray
        # Stage-Captures reads .logArchive off whatever it is handed, so the
        # capture entry stands in for the service object.
        Stage-Captures -Name $cap.component -Service $cap
    }
}

# The Quill capture is flow-level, not per-component: one book feeds the
# market-data simulator for the whole slice.
Write-Step 'Market-data capture (Quill)'
if (-not $plan.stagesCaptures) {
    # Not this host's job. Previously this said "no Quill capture declared for
    # this flow", which reads as a missing flow field rather than a host split.
    Write-Skip 'Quill is staged on the capture host, not this one'
}
elseif (-not $plan.quillCapture) {
    Write-Warn 'no Quill capture declared for this flow. The market-data simulator will have no book, so routing decisions constrained by order state exercise the no-market fallback path - a run that looks green while testing the wrong behaviour.'
    Add-Result '-' 'quillCapture' 'missing' @{ reason = 'not declared in the flow file' }
}
else {
    $quill = $plan.quillCapture
    Write-Ok "s3://$($quill.bucket)/$($quill.s3Path)"
    $quillDest = Join-Path $captureRoot '_quill'
    # Same correction as the FIX archive above: the exit code decides the status.
    # A failed Quill fetch recorded as 'staged' is the worst of the three - the
    # simulator starts with no book and the replay looks green while exercising
    # the no-market fallback path.
    $quillRc = 0
    if (-not $DryRun) {
        New-Item -ItemType Directory -Path $quillDest -Force | Out-Null
        $copy = Invoke-Aws @('s3','cp',"s3://$($quill.bucket)/$($quill.s3Path)","$quillDest\",'--only-show-errors') -AllowFailure
        $quillRc = $copy.ExitCode
        if ($quillRc -ne 0) {
            if ($copy.Output -match 'InvalidObjectState') {
                Write-Warn 'Quill capture is ARCHIVED (S3 Glacier / Intelligent-Tiering archive tier), not missing and not forbidden. Restore it before the replay, or pick a market date whose objects are still warm.'
                $script:QuillReason = 'object in an archived S3 access tier; restore required'
            }
            else {
                Write-Warn "Quill fetch failed (exit $quillRc). The key is a discovery HINT - the capture date may differ from the market date. A 403 here usually means the host role, not the key."
                $script:QuillReason = "aws s3 cp exited $quillRc"
            }
        }
    }
    if ($quillRc -eq 0) {
        Add-Result '-' 'quillCapture' 'staged' @{ bucket = $quill.bucket; key = $quill.s3Path; dest = $quillDest }
    }
    else {
        Add-Result '-' 'quillCapture' 'failed' @{
            bucket = $quill.bucket; key = $quill.s3Path
            reason = if ($script:QuillReason) { $script:QuillReason } else { "aws s3 cp exited $quillRc" } }
    }
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
    # UTF-8 WITHOUT A BOM, and not via Set-Content.
    #
    # `Set-Content -Encoding UTF8` in PowerShell 5.1 writes a byte-order mark:
    # the file begins EF BB BF and only then '{'. Build 73 lost a complete,
    # correct Windows manifest to exactly that. Staging succeeded, the manifest
    # was written, SSM returned it - and the pipeline's sanity check
    #     head -c 1 staged-windows.json | grep -q '{'
    # read 0xEF, decided nothing had come back, and deleted the file. The
    # contract then reported staging for one host instead of two.
    #
    # A BOM is also a hazard for any strict JSON parser downstream;
    # emit_environment.py happens to open with utf-8-sig and would have coped,
    # which is precisely why this would have kept slipping through.
    [System.IO.File]::WriteAllText(
        $manifestPath,
        ($document | ConvertTo-Json -Depth 8),
        (New-Object System.Text.UTF8Encoding($false)))
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
