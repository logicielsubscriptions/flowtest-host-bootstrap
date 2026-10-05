<#
.SYNOPSIS
    Start this host's engine containers from the flow plan.

.DESCRIPTION
    The Windows counterpart of scripts/05-start-engines.sh, and a thin driver
    over images/run-engine.ps1 rather than a second implementation of it.
    run-engine.ps1 already owns the create -> copy -> start sequence and the
    reasons for it (configuration must sit beside the binary; the engine must
    own its console). This script decides WHICH containers to start, in what
    order, with which image and address - all of it read from
    flow-plan-<role>.json.

    WHY A DRIVER AND NOT A LOOP IN THE PIPELINE
    The plan is the only place that knows the group structure, and groups are
    where the network decisions live. Putting that logic in Groovy would put it
    on the far side of an SSM call from the host it describes, and would make
    the Windows and Linux paths diverge for no reason.

    NOTHING STARTS IF AN IMAGE IS MISSING
    Every required tag is checked in the registry before the first container is
    created. A tag discovered missing half way through leaves some engines up
    and some down, which presents as an engine crash rather than as a registry
    gap - and the environment then has to be torn down and rebuilt to get a
    clean result.

.EXAMPLE
    .\05-start-engines.ps1 -Plan C:\FlowTest\bootstrap\flow-plan-windows.json

.EXAMPLE
    .\05-start-engines.ps1 -Only <containerName>,<containerName> -DryRun
#>
[CmdletBinding()]
param(
    [string]   $Plan,
    [string]   $Only,
    [string]   $EcrNamespace   = 'flowtest',
    [int]      $SettleSeconds  = 5,
    # THE SECOND LOOK, AND THE ONE THAT MATTERS. The order execution server -
    # which runs on THIS host - dies about 45 seconds after launch if it does
    # not own its console. A five-second check cannot see that. 90 clears it
    # with margin, and the wait is shared across all components on the host
    # rather than paid per engine.
    [int]      $LateCheckSeconds = 90,
    # Written by 06-restore-databases.sh on the host the database runs on, and
    # copied here by the pipeline: on this flow the engines that need a
    # database are NOT on the same machine as the database, so the evidence has
    # to travel. Absent is not the same as "restored nothing", and an engine
    # that needs a database is refused either way.
    [string]   $RestoreManifest = 'C:\FlowTest\restored-databases.json',
    # The flow-test SQL Server, and the secret holding its SA password. The
    # address is read from the plan when not given; the secret is the same one
    # 06-restore-databases.sh used to start the instance.
    # Both default from the plan / the caller. NO DEFAULT SECRET NAME: guessing
    # one and failing to read it would look like a permissions problem instead
    # of a missing argument, and the Jenkins job already passes the same secret
    # to 06-restore-databases.sh.
    [string]   $DbAddress,
    [string]   $DbSecretId,
    [switch]   $Replace,
    [switch]   $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ScriptVersion = '2026-10-05.1-sapassword-absent-ok'
Write-Host "  script version $script:ScriptVersion" -ForegroundColor DarkGray

function Write-Step { param([string] $m) Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string] $m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Warn { param([string] $m) Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Write-Skip { param([string] $m) Write-Host "  [skip] $m" -ForegroundColor DarkGray }
function Write-Fail { param([string] $m) Write-Host "  [FAIL] $m" -ForegroundColor Red }

# Native commands write to stderr for ordinary conditions, and under
# ErrorActionPreference='Stop' PowerShell turns that into a terminating error.
# Same reason as images/run-engine.ps1.
#
# AN EXPLICIT ARRAY, NOT ValueFromRemainingArguments - AND NO PARAMETER THAT
# COULD SWALLOW A PASSED-THROUGH FLAG.
#
# This was:
#     param([string] $File, [Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
# called as
#     Invoke-Native powershell -NoProfile -ExecutionPolicy Bypass -File $runEngine @args
# and PowerShell bound the `-File` I meant for powershell.exe to this function's
# own -File parameter. Everything after it shifted, and build 100 died with
#     A positional parameter cannot be found that accepts argument '-ConfigDir'
# which names an argument of a THIRD script and points nowhere near the cause.
#
# `docker inspect -f ...` was the same bug waiting: -f prefix-matches -File.
# Passing the arguments as one array removes the whole class - nothing inside
# an array is ever considered for parameter binding.
function Invoke-Native {
    param([Parameter(Mandatory)][string] $Exe,
          [string[]] $NativeArgs = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @NativeArgs 2>&1
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($out | Out-String).Trim() }
    }
    finally { $ErrorActionPreference = $prev }
}

trap {
    $inv = $_.InvocationInfo
    Write-Host ''
    Write-Fail "line $($inv.ScriptLineNumber): $($inv.Line.Trim())"
    Write-Fail $_.Exception.Message
    # KEEP THE RECORD. Build 135 died here after the Windows FIX hub was
    # already started: no started-windows.json, no late re-check, and a running
    # container nothing listed. A fatal error must not cost the manifest - write
    # what was done so far, plus the fault, so the build can say which engines
    # are up and which were never attempted. Every read is guarded: under
    # StrictMode an unset variable here would throw inside the trap.
    try {
        $wr = Get-Variable -Name workRoot -ValueOnly -ErrorAction SilentlyContinue
        $dr = Get-Variable -Name DryRun -ValueOnly -ErrorAction SilentlyContinue
        if ($wr -and -not $dr) {
            # Assigned first, then @(): Get-Variable -ValueOnly emits the array
            # as ONE object, so @(Get-Variable ...) nested it a level deep.
            $done = Get-Variable -Name results -ValueOnly -ErrorAction SilentlyContinue
            if ($null -eq $done) { $done = @() }
            $doc = [ordered]@{
                schemaVersion = '1.0'
                hostRole      = (Get-Variable -Name role -ValueOnly -ErrorAction SilentlyContinue)
                flow          = (Get-Variable -Name flow -ValueOnly -ErrorAction SilentlyContinue)
                startedBy     = $script:ScriptVersion
                startedAt     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
                fatal         = [ordered]@{ line = $inv.ScriptLineNumber; statement = "$($inv.Line.Trim())"
                                            message = "$($_.Exception.Message)"
                                            note = 'the script stopped here; components after this point were NOT attempted, and any listed as running were left running' }
                items         = @($done)
                summary       = @{ fatal = 1 }
            }
            $mp = Join-Path $wr "started-$($doc.hostRole).json"
            $doc | ConvertTo-Json -Depth 8 | Set-Content -Path $mp -Encoding UTF8
            Write-Fail "partial manifest written to $mp"
        }
    } catch { Write-Fail "could not write a partial manifest: $($_.Exception.Message)" }
    exit 1
}

# ---------------------------------------------------------------------------
# THE PLAN LIVES UNDER bootstrap\, NOT AT THE WORK ROOT.
#
# This defaulted to C:\FlowTest\flow-plan-windows.json and build 98 failed on
# both hosts with "flow plan not found" - one directory level off, in a path
# 04-stage-artifacts.ps1 has had right since it was written. The two scripts
# read the same file on the same host and each carried its own idea of where it
# is; verify-all.sh now asserts they agree, because the next person to add a
# host-side script will make the same guess.
if (-not $Plan) { $Plan = 'C:\FlowTest\bootstrap\flow-plan-windows.json' }
if (-not (Test-Path $Plan)) { Write-Fail "flow plan not found at $Plan"; exit 1 }

$planObj    = Get-Content -Raw $Plan | ConvertFrom-Json
$role       = $planObj.hostRole
$flow       = $planObj.flow
$configRoot = $planObj.staged.configRoot
$workRoot   = $planObj.workRoot
Write-Ok "flow $flow, role $role"
Write-Ok "config root $configRoot"

$runEngine = Join-Path $PSScriptRoot 'run-engine.ps1'
if (-not (Test-Path $runEngine)) {
    # The bootstrap tarball puts the images/ scripts alongside scripts/. If the
    # layout ever changes this must fail loudly rather than silently reimplement
    # the start sequence, which is the one thing this file must not do.
    $runEngine = Join-Path (Split-Path -Parent $PSScriptRoot) 'images\run-engine.ps1'
}
if (-not (Test-Path $runEngine)) { Write-Fail "run-engine.ps1 not found next to this script or in images/"; exit 1 }
Write-Ok "using $runEngine"

# ---------------------------------------------------------------------------
Write-Step 'Registry'
$region = $null
try {
    $token  = Invoke-RestMethod -Method Put -Uri 'http://169.254.169.254/latest/api/token' `
                -Headers @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '60' } -TimeoutSec 5
    $region = Invoke-RestMethod -Uri 'http://169.254.169.254/latest/meta-data/placement/region' `
                -Headers @{ 'X-aws-ec2-metadata-token' = $token } -TimeoutSec 5
} catch {
    Write-Warn "IMDS did not answer: $($_.Exception.Message)"
}
if (-not $region) { Write-Fail 'could not determine the region from instance metadata'; exit 1 }

$idn = Invoke-Native aws @('sts','get-caller-identity','--query','Account','--output','text')
if ($idn.ExitCode -ne 0 -or -not $idn.Output) {
    Write-Fail "could not read the account id: $($idn.Output)"; exit 1
}
$registry = "$($idn.Output).dkr.ecr.$region.amazonaws.com"
Write-Ok $registry

# THE DOCKER DAEMON NEEDS ITS OWN LOGIN. The instance role authorises the AWS
# CLI, and the availability check below rides on that - but `docker pull` never
# touches the CLI. Build 100 made the distinction concrete: the tag check
# reported [ok] and the pull immediately failed with
#   pull access denied ... no basic auth credentials
# The check had told the truth (the image exists) and answered a question
# nobody was asking. Logging in first puts both on the same credentials.
#
# Password through STDIN, never as an argument - a command line is readable in
# the process table. Same form as images/build-images.ps1.
if (-not $DryRun) {
    $pwOut = Invoke-Native aws @('ecr','get-login-password','--region',$region)
    if ($pwOut.ExitCode -ne 0) {
        Write-Fail "aws ecr get-login-password failed: $($pwOut.Output)"; exit 1
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $loginOut = ("$($pwOut.Output)" | & docker login --username AWS --password-stdin $registry 2>&1 | Out-String)
    $loginRc = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($loginRc -ne 0) {
        Write-Fail "docker login to $registry failed: $($loginOut.Trim())"
        Write-Fail 'The daemon cannot pull the engine images. The instance role may lack ecr:GetAuthorizationToken.'
        exit 1
    }
    Write-Ok 'docker logged in to the registry'
}

# ---------------------------------------------------------------------------
# Flatten groups into an ordered list, carrying each group's network identity.
# The FIRST service in a shared-namespace group owns the namespace; the rest
# join it by container name. The plan's namespaceContainer says the same thing
# as of 2026-09-21 - before that it named a pause container nothing created.
$services = @()
foreach ($group in @($planObj.groups)) {
    $svcList = @($group.services)
    for ($i = 0; $i -lt $svcList.Count; $i++) {
        $services += [pscustomobject]@{
            Name      = $svcList[$i].containerName
            Service   = $svcList[$i].serviceName
            Family    = $svcList[$i].imageFamily
            # imageTag, not tag. An engine that needs a database carries a
            # baked ODBC data source, so its image is per component and the
            # generator names it accordingly. Falling back to tag keeps a plan
            # from an older generator working rather than pulling nothing.
            Tag       = $(if ($svcList[$i].PSObject.Properties['imageTag'] -and $svcList[$i].imageTag) { [string]$svcList[$i].imageTag } else { [string]$svcList[$i].tag })
            Network   = $group.dockerNetwork
            Ip        = $group.ip
            Shared    = [bool]$group.sharedNamespace
            IsFirst   = ($i -eq 0)
            Owner     = $svcList[0].containerName
            # Where the staged config goes INSIDE the container. From the plan,
            # never guessed here: the Linux driver hardcoded the wrong path and
            # the engine silently ran the config baked into its image.
            Target    = $svcList[$i].containerConfigTarget
            # Whether this engine needs a restored database, and which one.
            # [bool] on a possibly-absent property: under StrictMode a bare
            # $x.missing THROWS, and this whole object exists to be read with
            # dotted access in the loops below.
            NeedsDb   = [bool]$svcList[$i].needsDatabase
            DbName    = "$($svcList[$i].dbName)"
            # Empty directories the engine needs and will not create itself.
            ReqDirs   = @($svcList[$i].requiredEmptyDirs)
        }
    }
}
if ($services.Count -eq 0) { Write-Fail 'the plan lists no services for this host'; exit 1 }

if ($Only) {
    # A LIST, not one name - Phase 0 starts the two FIX hubs deliberately, and
    # naming them one run at a time would leave the host half started between
    # runs. Split and trimmed here so the caller can pass either form.
    $wanted = @($Only -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $services = @($services | Where-Object { $wanted -contains $_.Name })
    if ($services.Count -eq 0) { Write-Fail "-Only '$Only' matched no component in this plan"; exit 1 }
    Write-Ok "restricted to $($services.Count) of the plan's components by -Only"
}

# ---------------------------------------------------------------------------
Write-Step "Image availability ($($services.Count) component(s))"
$missing = @()
foreach ($s in $services) {
    $repo = "$EcrNamespace/$($s.Family)"
    $q = Invoke-Native aws @('ecr','describe-images','--repository-name',$repo,
                             '--image-ids',"imageTag=$($s.Tag)",'--region',$region)
    if ($q.ExitCode -eq 0) { Write-Ok "${repo}:$($s.Tag)" }
    else {
        $missing += "${repo}:$($s.Tag)  (for $($s.Service))"
        Write-Fail "${repo}:$($s.Tag) NOT in the registry"
    }
}
if ($missing.Count -gt 0) {
    Write-Host ''
    Write-Fail "$($missing.Count) image tag(s) missing. Nothing was started."
    $missing | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
    Write-Host '         Build and push them with images\build-images.ps1, then re-run.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------

function Get-IniValue {
    <#  One key out of one section of an INI file, case-insensitively.
        Returns $null when the file, the section or the key is absent - the
        caller decides whether that is fatal. #>
    param([Parameter(Mandatory)][string] $Path,
          [Parameter(Mandatory)][string] $Section,
          [Parameter(Mandatory)][string] $Key)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $cur = $null
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $t = $line.Trim()
        if ($t.StartsWith('[') -and $t.EndsWith(']')) { $cur = $t.Substring(1, $t.Length - 2).Trim(); continue }
        if ($cur -ne $Section) { continue }
        if ($t.StartsWith(';') -or $t.StartsWith('#') -or -not $t.Contains('=')) { continue }
        if ($t.Split('=', 2)[0].Trim() -ieq $Key) { return $t.Split('=', 2)[1].Trim() }
    }
    return $null
}

function Compare-ImageDataSource {
    <#  WHICH DATA SOURCE WAS THIS IMAGE BUILT FOR, AND IS IT THE ONE THIS RUN NEEDS?

        The ODBC data source is baked into a database engine's image at build
        time and recorded on it as labels. ECR tags are IMMUTABLE and the tag
        does not change when the data source does - so correcting the server,
        database or DSN name and re-pushing is rejected, build-images used to
        report the existing tag as "already in ECR - nothing to build", and the
        engine then started against the OLD data source with every step green.

        Pure: labels in, list of mismatches out. An image with no labels at all
        predates them and cannot be vouched for, so absence is a mismatch.

        Case-INsensitive on purpose: ODBC resolves DSN names case-insensitively
        and SQL Server database names are compared under the server collation,
        so a case-only difference is not a different data source.

        IDENTICAL TEXT in images/build-images.ps1; verify-all compares them. #>
    param($Labels, [string] $Dsn, [string] $Server, [string] $Database)
    $want = [ordered]@{
        'com.logiciel.flowtest.odbcDsn'      = $Dsn
        'com.logiciel.flowtest.odbcServer'   = $Server
        'com.logiciel.flowtest.odbcDatabase' = $Database
    }
    $bad = @()
    foreach ($k in $want.Keys) {
        $have = if ($null -ne $Labels -and $Labels.PSObject.Properties[$k]) { [string]$Labels.PSObject.Properties[$k].Value } else { '<absent>' }
        if ($have -ne $want[$k]) {
            $bad += "$($k.Split('.')[-1]): the image has '$have', this run needs '$($want[$k])'"
        }
    }
    # NOT `return ,$bad`. Every caller wraps this in @(...), and the comma
    # form hands @() an array CONTAINING an empty array - Count 1 - so a
    # matching image read as one mismatch and every correct image would have
    # been refused. Caught by tests/Test-ImageDataSource.ps1 before it shipped.
    return $bad
}

function Get-ImageLabels {
    <#  Pull the image and read its labels. The pull is not extra work: the
        container create that follows would pull it anyway. #>
    param([Parameter(Mandatory)][string] $Image)
    $p = Invoke-Native docker @('pull', $Image)
    if ($p.ExitCode -ne 0) { return [pscustomobject]@{ ok = $false; labels = $null; error = "docker pull failed: $($p.Output)" } }
    $i = Invoke-Native docker @('image', 'inspect', '--format', '{{json .Config.Labels}}', $Image)
    if ($i.ExitCode -ne 0) { return [pscustomobject]@{ ok = $false; labels = $null; error = "docker image inspect failed: $($i.Output)" } }
    try { $labels = ("$($i.Output)".Trim() | ConvertFrom-Json) }
    catch { return [pscustomobject]@{ ok = $false; labels = $null; error = "the image labels are not readable JSON: $($i.Output)" } }
    return [pscustomobject]@{ ok = $true; labels = $labels; error = $null }
}

function Grant-EngineDbLogin {
    <#  MAKE THE STAND-IN DATABASE ACCEPT THE CREDENTIAL THE ENGINE CARRIES.

        The engine authenticates with USER/PWD from its own staged
        ServerConfiguration.ini - production's credential, arriving with
        production's config. The flow-test SQL Server knows only SA, so without
        this the engine reaches the server and is refused, which looks nothing
        like a missing login three layers downstream.

        The substitute conforms to the system under test, not the other way
        round: we do NOT rewrite the engine credential, because that would be a
        declared deviation on every database engine on every run.

        CHECK_POLICY = OFF is required, not laziness. Production passwords here
        are shorter than SQL Server's complexity minimum, so a plain CREATE
        LOGIN is rejected outright.

        NO PASSWORD REACHES A COMMAND LINE. The T-SQL goes in through a file
        that is created with an owner-only ACL and deleted in a finally block;
        SA authenticates through SQLCMDPASSWORD in the child environment. This
        script has twice had to fix the other shape. #>
    param([Parameter(Mandatory)][string] $Server,
          [Parameter(Mandatory)][string] $Database,
          [Parameter(Mandatory)][string] $Login,
          [Parameter(Mandatory)][string] $Password,
          [Parameter(Mandatory)][string] $SaPassword)

    $sqlcmd = (Get-Command sqlcmd -ErrorAction SilentlyContinue)
    if (-not $sqlcmd) {
        return [pscustomobject]@{ ok = $false; error = 'sqlcmd is not installed on this host, so the engine login cannot be provisioned. Re-run 02-prereq-windows.ps1 - the SQL client tools step is marked optional and may have been skipped.' }
    }

    # ' is the escape for ' inside a T-SQL string literal. A password holding
    # one would otherwise end the literal and the rest would be parsed as SQL.
    $pwLit = $Password.Replace("'", "''")
    $sql = @"
SET NOCOUNT ON;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'$Login')
    CREATE LOGIN [$Login] WITH PASSWORD = N'$pwLit', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
ELSE
    ALTER LOGIN [$Login] WITH PASSWORD = N'$pwLit', CHECK_POLICY = OFF, CHECK_EXPIRATION = OFF;
ALTER LOGIN [$Login] ENABLE;
USE [$Database];
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'$Login')
    CREATE USER [$Login] FOR LOGIN [$Login];
ELSE
    ALTER USER [$Login] WITH LOGIN = [$Login];
ALTER ROLE [db_owner] ADD MEMBER [$Login];
PRINT 'LOGIN_PROVISIONED';
"@

    $file = Join-Path $env:TEMP ("flowtest-login-" + [guid]::NewGuid().ToString('N') + '.sql')
    try {
        # Owner-only before a byte of it exists, not after.
        $null = New-Item -ItemType File -Path $file -Force
        $acl = Get-Acl $file
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner([System.Security.Principal.NTAccount]::new($env:USERNAME))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $env:USERNAME, 'FullControl', 'Allow')))
        Set-Acl -Path $file -AclObject $acl
        [System.IO.File]::WriteAllText($file, $sql, (New-Object System.Text.UTF8Encoding $false))

        $prevPw = $env:SQLCMDPASSWORD
        try {
            $env:SQLCMDPASSWORD = $SaPassword
            $out = & sqlcmd -S $Server -U sa -C -b -h -1 -W -i $file 2>&1 | Out-String
            $rc = $LASTEXITCODE
        } finally {
            $env:SQLCMDPASSWORD = $prevPw
        }
        if ($rc -ne 0 -or $out -notmatch 'LOGIN_PROVISIONED') {
            return [pscustomobject]@{ ok = $false; error = "sqlcmd exit $rc. $($out.Trim())" }
        }

        # THE EXIT CODE IS NOT THE VERDICT. Log in AS the engine would.
        $prevPw = $env:SQLCMDPASSWORD
        try {
            $env:SQLCMDPASSWORD = $Password
            $probe = & sqlcmd -S $Server -U $Login -d $Database -C -b -h -1 -W -Q 'SELECT 1' 2>&1 | Out-String
            $prc = $LASTEXITCODE
        } finally {
            $env:SQLCMDPASSWORD = $prevPw
        }
        if ($prc -ne 0) {
            return [pscustomobject]@{ ok = $false; error = "the login was created but could not connect with it: sqlcmd exit $prc. $($probe.Trim())" }
        }
        return [pscustomobject]@{ ok = $true; error = $null }
    } finally {
        Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
    }
}

function Copy-EngineLogs {
    <#  PULL THE ENGINE'S OWN LOG OUT OF A CONTAINER THAT DIED.

        `docker logs` is stdout only. These engines write a g3log FILE next to
        the binary, and it holds what happened before the crash. Build 121's
        RISK engine aborted with SIGABRT and the console carried nothing but
        the stack dump, so three runs were spent guessing at causes the engine
        had already written down - and the top frame of that dump is g3log's
        crash HANDLER, which reads like the cause and is not.

        Best-effort: a container with no log is not an extra failure, and this
        must never mask the real one. Mirrors capture_engine_logs in the .sh. #>
    param([Parameter(Mandatory)][string] $Name, [string] $Target)
    if (-not $Target) { return }
    $dest = Join-Path $workRoot "engine-logs\$Name"
    $null = New-Item -ItemType Directory -Path $dest -Force -ErrorAction SilentlyContinue
    $tmp = Join-Path $env:TEMP "flowtest-logs-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $tmp -Force
    $cp = Invoke-Native docker @('cp', "${Name}:$Target", $tmp)
    if ($cp.ExitCode -eq 0) {
        # '*.log' ONLY. The previous filter also took '*g3log*', which matches
        # g3log.dll - the LIBRARY, not a log. Build 129's captured archive
        # contained exactly one member: a 360 KB DLL, and no logs at all. The
        # engine's own file is named like
        # Internal_LSL_Modules.g3log.20260924-080939.log, so the extension
        # alone finds it.
        $logs = @(Get-ChildItem -Path $tmp -Recurse -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Extension -eq '.log' })
        foreach ($f in $logs) { Copy-Item $f.FullName -Destination $dest -Force -ErrorAction SilentlyContinue }
        if ($logs.Count -gt 0) {
            Write-Warn "${Name}: copied $($logs.Count) engine log file(s) to $dest - READ THESE, not the stack dump"
        } else {
            Write-Warn "${Name}: the container had no log files to copy"
        }
    } else {
        Write-Warn "${Name}: could not copy logs out of the container"
    }
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$results = @()
$startedNames = @()
$script:FirstStart = $null
# Read by `if (-not $script:SaPassword)` before the first database engine sets
# it. Under StrictMode reading an UNSET variable is a terminating error, and
# build 135 died on exactly that line - the first run ever to reach it, because
# no earlier run had got an order-management engine past its image check.
$script:SaPassword = $null
$started = 0
$failed  = 0

foreach ($s in $services) {
    Write-Step $s.Name
    # Evidence of the declared ENVIRONMENT deviations this engine runs under
    # (hosts-map.json environmentDeviations), read from what was actually
    # applied - the image's labels and the grant - not from the catalogue.
    # Reset per engine: a value left over from the previous one would record a
    # deviation against an engine that has no database at all.
    $envEvidence = $null

    # A DATABASE THIS ENGINE NEEDS AND DOES NOT HAVE.
    #
    # Checked FIRST, before configuration, because it is the more dangerous
    # gap: an engine with no config fails visibly, and an order execution
    # server with no database can sit there looking healthy while answering
    # nothing - which reads downstream as a routing fault, three layers from
    # the cause. The restore manifest is the only evidence accepted; a
    # reachable port is not.
    if ($s.NeedsDb) {
        $dbState = 'no manifest'
        if (Test-Path -LiteralPath $RestoreManifest) {
            try {
                $rm = Get-Content -LiteralPath $RestoreManifest -Raw | ConvertFrom-Json
                $row = @($rm.items | Where-Object { $_.database -eq $s.DbName }) | Select-Object -First 1
                $dbState = if ($row) { $row.status } else { 'not in the manifest' }
            } catch { $dbState = 'unreadable manifest' }
        }
        if ($dbState -ne 'restored') {
            Write-Fail "$($s.Name): needs the database '$($s.DbName)', which is '$dbState'."
            Write-Fail '       NOT starting it. This engine does not fail loudly without its database -'
            Write-Fail '       it can run and answer nothing, which reads downstream as a routing fault.'
            Write-Fail "       See $RestoreManifest, and the dbBackup entries in the staging manifest."
            $results += [pscustomobject]@{ component = $s.Name; status = 'refused'
                detail = @{ reason = 'the database this engine needs was not restored'
                            dbName = $s.DbName; databaseStatus = "$dbState"
                            restoreManifest = $RestoreManifest } }
            $failed++; continue
        }
        Write-Ok "database $($s.DbName) is restored"

        # THE IMAGE MUST HAVE BEEN BUILT FOR THIS DATA SOURCE.
        #
        # Checked here, at the point of use, and before the login is created -
        # nothing is changed on the database server for an engine that will
        # not start. See Compare-ImageDataSource for why a tag that exists
        # proves nothing about which data source is inside it.
        if (-not $DbAddress) { $DbAddress = "$($planObj.databaseAddress)" }
        $svcIniDsn = Join-Path (Join-Path $configRoot $s.Name) 'ServerConfiguration.ini'
        $wantDsn = Get-IniValue -Path $svcIniDsn -Section 'ServerDatabaseSettings' -Key 'DSN'
        $imgRef = "$registry/$EcrNamespace/$($s.Family):$($s.Tag)"
        if (-not $DryRun) {
            $lab = Get-ImageLabels -Image $imgRef
            $mismatch = @(if ($lab.ok) { @(Compare-ImageDataSource -Labels $lab.labels -Dsn "$wantDsn" -Server "$DbAddress" -Database $s.DbName) } else { @() })
            if (-not $lab.ok -or $mismatch.Count -gt 0) {
                Write-Fail "$($s.Name): $imgRef was NOT built for the data source this run needs."
                if (-not $lab.ok) { Write-Fail "       $($lab.error)" }
                foreach ($m in $mismatch) { Write-Fail "       $m" }
                Write-Fail '       NOT starting it. It would connect to the data source baked into the image,'
                Write-Fail '       and every step before this one would still read green. ECR tags are immutable,'
                Write-Fail '       so re-pushing cannot fix it - delete the tag and rebuild:'
                Write-Fail "         aws ecr batch-delete-image --repository-name $EcrNamespace/$($s.Family) --image-ids imageTag=$($s.Tag) --region $region"
                Write-Fail '         then images\build-images.ps1, which now refuses to skip a mismatched image.'
                $results += [pscustomobject]@{ component = $s.Name; status = 'refused'
                    detail = @{ reason = 'the image was built for a different ODBC data source than this run needs'
                                image = $imgRef; mismatches = @($mismatch); error = "$($lab.error)"
                                wantDsn = "$wantDsn"; wantServer = "$DbAddress"; wantDatabase = $s.DbName } }
                $failed++; continue
            }
            Write-Ok "image built for DSN $wantDsn -> $DbAddress / $($s.DbName) (read from its labels)"
            $labelOf = { param($n) if ($null -ne $lab.labels -and $lab.labels.PSObject.Properties[$n]) { [string]$lab.labels.PSObject.Properties[$n].Value } else { '<absent>' } }
            $envEvidence = [ordered]@{
                'odbc-encryption-off' = [ordered]@{ Encrypt = (& $labelOf 'com.logiciel.flowtest.odbcEncrypt')
                                                    TrustServerCertificate = (& $labelOf 'com.logiciel.flowtest.odbcTrustServerCertificate')
                                                    source = 'image labels' }
            }
        }

        # THE LOGIN THE ENGINE WILL USE.
        #
        # Restored is not the same as reachable-as-this-engine. The flow-test
        # SQL Server is created knowing only SA; the engine authenticates with
        # the credential in its own staged config. Provisioned here, where both
        # the credential and a route to the database exist - the restore script
        # runs on the Linux host and has neither.
        $svcIni = Join-Path (Join-Path $configRoot $s.Name) 'ServerConfiguration.ini'
        $dbUser = Get-IniValue -Path $svcIni -Section 'ServerDatabaseSettings' -Key 'USER'
        $dbPw   = Get-IniValue -Path $svcIni -Section 'ServerDatabaseSettings' -Key 'PWD'
        if (-not $dbUser -or -not $dbPw) {
            Write-Fail "$($s.Name): [ServerDatabaseSettings] USER/PWD are not in $svcIni,"
            Write-Fail '       so the login this engine will use cannot be provisioned. NOT starting it:'
            Write-Fail '       it would reach the database and be refused, which reads as a routing fault.'
            $results += [pscustomobject]@{ component = $s.Name; status = 'refused'
                detail = @{ reason = 'no [ServerDatabaseSettings] USER/PWD in the staged configuration'
                            configFile = $svcIni; dbName = $s.DbName } }
            $failed++; continue
        }
        # $planObj, NOT $plan. PowerShell names are case-insensitive, so in this
        # script $plan IS the -Plan parameter - the path STRING - and reading
        # .databaseAddress off a string is a terminating error under StrictMode.
        # The Jenkinsfile never passes -DbAddress, so this would have killed the
        # Windows start step the first time an OMS engine got this far. Found
        # 2026-09-28 by reading the code, not by a run: no run had reached it.
        if (-not $DbAddress) { $DbAddress = "$($planObj.databaseAddress)" }
        if (-not $DbAddress -or -not $DbSecretId) {
            $why = if (-not $DbAddress) { 'the plan carries no databaseAddress' } else { '-DbSecretId was not given' }
            Write-Fail "$($s.Name): cannot provision its database login - $why."
            Write-Fail '       NOT starting it: it would reach the database and be refused.'
            $results += [pscustomobject]@{ component = $s.Name; status = 'refused'
                detail = @{ reason = 'the database address or SA secret id is not available, so no engine login could be provisioned'
                            dbName = $s.DbName; dbServer = "$DbAddress"; secretId = "$DbSecretId" } }
            $failed++; continue
        }
        if (-not $script:SaPassword) {
            $sec = Invoke-Native aws @('secretsmanager','get-secret-value','--secret-id',$DbSecretId,
                                       '--query','SecretString','--output','text')
            if ($sec.ExitCode -ne 0 -or -not "$($sec.Output)".Trim()) {
                Write-Fail "$($s.Name): could not read $DbSecretId from Secrets Manager, so the engine"
                Write-Fail '       login cannot be provisioned. The instance role grants flowtest/* only.'
                $results += [pscustomobject]@{ component = $s.Name; status = 'refused'
                    detail = @{ reason = 'the SA secret could not be read, so no engine login could be created'
                                secretId = $DbSecretId; dbName = $s.DbName } }
                $failed++; continue
            }
            $script:SaPassword = "$($sec.Output)".Trim()
        }
        $grant = Grant-EngineDbLogin -Server $DbAddress -Database $s.DbName `
                                     -Login $dbUser -Password $dbPw -SaPassword $script:SaPassword
        if (-not $grant.ok) {
            Write-Fail "$($s.Name): could not provision the database login '$dbUser' on $DbAddress."
            Write-Fail "       $($grant.error)"
            $results += [pscustomobject]@{ component = $s.Name; status = 'refused'
                detail = @{ reason = 'the login this engine authenticates with could not be provisioned'
                            dbName = $s.DbName; dbLogin = $dbUser; dbServer = $DbAddress
                            error = "$($grant.error)" } }
            $failed++; continue
        }
        # The LOGIN NAME is recorded, never the password.
        Write-Ok "database login '$dbUser' provisioned on $DbAddress and verified by connecting with it"
        $dbLoginProvisioned = $dbUser
        if ($envEvidence) { $envEvidence['engine-login-db-owner'] = [ordered]@{ login = $dbUser; role = 'db_owner'; verifiedByConnecting = $true } }
    }

    $configDir = Join-Path $configRoot $s.Name

    if (-not (Test-Path $configDir)) {
        Write-Fail "$($s.Name): no staged configuration at $configDir - not starting it"
        $results += [pscustomobject]@{ component = $s.Name; status = 'refused'
            detail = @{ reason = 'no staged configuration directory; staging must run first'; dir = $configDir } }
        $failed++; continue
    }
    $files = @(Get-ChildItem -File -Path $configDir -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        # An engine started without configuration does not fail - it runs on
        # defaults and looks like a configuration bug somewhere else entirely.
        Write-Fail "$($s.Name): staged configuration directory is EMPTY - not starting it"
        $results += [pscustomobject]@{ component = $s.Name; status = 'refused'
            detail = @{ reason = 'staged configuration directory is empty'; dir = $configDir } }
        $failed++; continue
    }

    if (-not $s.Target) {
        Write-Fail "$($s.Name): the plan carries no containerConfigTarget for image family '$($s.Family)'."
        Write-Fail "         Refusing to guess - a wrong target means the engine silently runs its baked-in config."
        $results += [pscustomobject]@{ component = $s.Name; status = 'refused'
            detail = @{ reason = 'no containerConfigTarget in the plan for this image family'; imageFamily = $s.Family } }
        $failed++; continue
    }

    $image = "$registry/$EcrNamespace/$($s.Family):$($s.Tag)"
    # -EngineHome is run-engine.ps1's copy target. Passing the plan's value
    # makes the two agree by construction rather than by coincidence.
    $engineArgs = @('-Name', $s.Name, '-Image', $image, '-ConfigDir', $configDir,
                    '-EngineHome', $s.Target)
    if ($s.Shared -and -not $s.IsFirst) {
        # THE OWNER HAS TO BE ALIVE, AND ITS DEATH IS NOT THIS ENGINE'S FAULT.
        #
        # Build 121: the RISK engine died and the OE that shares its namespace
        # failed with "cannot join network of a non-running container", which
        # reads as an independent fault on the OE and is a consequence of the
        # other engine's crash. Said plainly so the manifest points at the
        # component that actually failed.
        $ownerUp = @((Invoke-Native docker @('ps','--format','{{.Names}}')).Output -split "`r?`n" |
                     Where-Object { $_.Trim() -eq $s.Owner })
        if ($ownerUp.Count -eq 0) {
            Write-Fail "$($s.Name): its namespace owner '$($s.Owner)' is not running, so it cannot start."
            Write-Fail '       This is a CONSEQUENCE, not this engine''s own fault - these two share'
            Write-Fail "       one production address, so look at why '$($s.Owner)' stopped."
            $results += [pscustomobject]@{ component = $s.Name; status = 'refused'
                detail = @{ reason = 'the namespace owner is not running'; namespaceOwner = $s.Owner
                            note = 'consequence of the owner failing; diagnose that component, not this one' } }
            $failed++; continue
        }
        $engineArgs += @('-NamespaceContainer', $s.Owner)
    } else {
        if ($s.Network) { $engineArgs += @('-Network', $s.Network) }
        if ($s.Ip)      { $engineArgs += @('-Ip', $s.Ip) }
    }
    # Plan-driven empty directories the engine needs before it starts. Passed
    # as separate argv entries so PowerShell does not re-split them.
    foreach ($d in @($s.ReqDirs)) { if ($d) { $engineArgs += @('-RequiredEmptyDirs', $d) } }
    if ($Replace) { $engineArgs += '-Replace' }
    if ($DryRun)  { $engineArgs += '-DryRun' }

    $run = Invoke-Native powershell (@('-NoProfile','-ExecutionPolicy','Bypass','-File',$runEngine) + $engineArgs)
    $run.Output -split "`r?`n" | Where-Object { $_ } | ForEach-Object { Write-Host "    $_" }

    if ($DryRun) {
        $results += [pscustomobject]@{ component = $s.Name; status = 'dry-run'; detail = @{ image = $image } }
        continue
    }
    if ($run.ExitCode -ne 0) {
        # A DEAD NAMESPACE HOLDER IS A CONSEQUENCE, NOT THIS ENGINE'S FAULT.
        #
        # The pre-flight check above asks docker ps whether the holder is up,
        # but it cannot close the race: build 129's RISK engine was running at
        # that moment and had aborted by the time `docker start` ran, so the
        # OE's manifest entry read only "run-engine.ps1 exited 1" - a dead end
        # pointing at the wrong component. Recognise docker's own words and
        # say whose failure this actually is.
        $joinFail = "$($run.Output)" -match 'cannot join network of a non[- ]running container'
        if ($joinFail) {
            Write-Fail "$($s.Name): could not start because its namespace owner '$($s.Owner)' is not running."
            Write-Fail '       This is a CONSEQUENCE, not this engine''s own fault - these two share'
            Write-Fail "       one production address, so diagnose '$($s.Owner)', not this component."
            $results += [pscustomobject]@{ component = $s.Name; status = 'refused'
                detail = @{ reason = 'the namespace owner stopped before this engine could join it'
                            namespaceOwner = $s.Owner; image = $image
                            note = 'consequence of the owner failing; diagnose that component, not this one' } }
            $failed++; continue
        }
        Write-Fail "$($s.Name): run-engine.ps1 exited $($run.ExitCode)"
        $results += [pscustomobject]@{ component = $s.Name; status = 'failed'
            detail = @{ reason = "run-engine.ps1 exited $($run.ExitCode)"; image = $image } }
        $failed++; continue
    }

    # run-engine.ps1 checks the container three seconds in. This checks again
    # after the settle window, because the failure this project actually fears
    # here is an engine that starts, is observed running, and dies shortly
    # afterwards - which is exactly the shape of the console-signal fault.
    Start-Sleep -Seconds $SettleSeconds
    $state = (Invoke-Native docker @('inspect','-f','{{.State.Status}}',$s.Name)).Output
    if ($state -ne 'running') {
        # THE EXIT CODE, NOT JUST THE STATE. The Linux hub's production unit file
        # carries SuccessExitStatus=11, so an exit code can mean "stopped
        # normally" for one family and "configuration error" for another -
        # a distinction the word "exited" throws away.
        $code = (Invoke-Native docker @('inspect','-f','{{.State.ExitCode}}',$s.Name)).Output
        Write-Fail "$($s.Name): container is '$state' (exit $code) $SettleSeconds s after start. Last output:"
        (Invoke-Native docker @('logs','--tail','30',$s.Name)).Output -split "`r?`n" |
            ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
        Copy-EngineLogs -Name $s.Name -Target $s.Target
        $results += [pscustomobject]@{ component = $s.Name; status = 'exited'
            detail = @{ reason = 'did not stay running'; state = "$state"; exitCode = "$code"; image = $image } }
        $failed++; continue
    }
    Write-Ok "running ($SettleSeconds s after start) - NOT yet a claim; see the late re-check below"
    $results += [pscustomobject]@{ component = $s.Name; status = 'running'
        detail = @{ image = $image; address = $s.Ip; network = $s.Network; configDir = $configDir
                    containerConfigTarget = $s.Target
                    environmentDeviations = $envEvidence
                    note = 'running at this instant. Superseded by the late re-check if one ran.' } }
    $startedNames += $s.Name
    if (-not $script:FirstStart) { $script:FirstStart = Get-Date }
    $started++
}

# ---------------------------------------------------------------------------
# LATE RE-CHECK.
#
# Everything above establishes that a container STARTED. This establishes that
# it is still there once the window in which the order execution server is
# known to kill itself - about 45 seconds, when it does not own its console -
# has passed. Those are different claims, and this host runs the very engine
# family the constraint was discovered on, so a five-second verdict here would
# be the most expensive false green this project could produce.
if ($startedNames.Count -gt 0 -and -not $DryRun) {
    $elapsed = [int]((Get-Date) - $script:FirstStart).TotalSeconds
    $remaining = $LateCheckSeconds - $elapsed
    Write-Step "Late re-check ($LateCheckSeconds s after the first engine started)"
    if ($remaining -gt 0) {
        Write-Host "         waiting $remaining s"
        Start-Sleep -Seconds $remaining
    }
    foreach ($n in $startedNames) {
        $age = [int]((Get-Date) - $script:FirstStart).TotalSeconds
        $state = (Invoke-Native docker @('inspect','-f','{{.State.Status}}',$n)).Output
        $row = $results | Where-Object { $_.component -eq $n } | Select-Object -First 1
        if ($state -eq 'running') {
            Write-Ok "$n still running after $age s"
            if ($row) {
                $row.detail.secondsObserved = $age
                $row.detail.note = 'still running at the late re-check, past the window in which this engine family self-terminates without a console'
            }
        } else {
            $code = (Invoke-Native docker @('inspect','-f','{{.State.ExitCode}}',$n)).Output
            Write-Fail "${n}: was running at $SettleSeconds s and is '$state' (exit $code) at $age s. Last output:"
            (Invoke-Native docker @('logs','--tail','30',$n)).Output -split "`r?`n" |
                ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
            $svcRow = @($services | Where-Object { $_.Name -eq $n }) | Select-Object -First 1
            if ($svcRow) { Copy-EngineLogs -Name $n -Target $svcRow.Target }
            if ($row) {
                $row.status = 'exited-late'
                $row.detail.state = "$state"
                $row.detail.exitCode = "$code"
                $row.detail.secondsObserved = $age
                # NAME THE OBSERVATION, NOT A CAUSE. This used to assert the
                # console-ownership fault. Build 119's RISK engine died with
                # SIGABRT and exit 3 about twenty seconds in, which is not that
                # fault at all - the console shape is a SIGINT the engine never
                # received. The manifest was therefore about to record a
                # diagnosis the evidence in the same file contradicted.
                $row.detail.reason = 'started, then stopped before the late re-check'
                $row.detail.diagnosis = 'NOT DIAGNOSED HERE. The console-ownership fault is a SIGINT the engine never received; an abort, a configuration error or a failed dependency look nothing like it. Read the exit code and the logs above.'
                $row.detail.note = "the earlier 'running' reading was taken at $SettleSeconds s and did not survive"
            }
            $started--; $failed++
        }
    }
}

# ---------------------------------------------------------------------------
Write-Step 'Manifest'
$manifest = Join-Path $workRoot "started-$role.json"
if ($DryRun) {
    Write-Skip "dry run - $manifest not written"
} else {
    $summary = @{}
    foreach ($r in $results) {
        if ($summary.ContainsKey($r.status)) { $summary[$r.status]++ } else { $summary[$r.status] = 1 }
    }
    $doc = [ordered]@{
        schemaVersion = '1.0'
        hostRole      = $role
        flow          = $flow
        startedBy     = $script:ScriptVersion
        startedAt     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        items         = $results
        summary       = $summary
    }
    $dir = Split-Path -Parent $manifest
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $doc | ConvertTo-Json -Depth 8 | Set-Content -Path $manifest -Encoding UTF8
    Write-Ok "wrote $manifest"
}

Write-Host ''
Write-Host "  started: $started"
Write-Host "  failed:  $failed"

if ($failed -gt 0) { exit 1 }
exit 0
