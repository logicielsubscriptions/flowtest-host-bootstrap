<#
.SYNOPSIS
    Start one engine container with its config delivered into the engine's own
    directory, and without a wrapper process.

.DESCRIPTION
    Implements the create -> cp -> start sequence that both engine constraints
    force on us:

    CONSTRAINT 1 - config location.
    The engine has no config-path argument and no config environment variable.
    It reads its configuration from the directory it runs in, so the files must
    physically sit next to the binary. A directory bind mount there would hide
    the image contents including the binary, and Windows containers cannot
    bind-mount single files. So we copy into the created-but-not-started
    container.

    CONSTRAINT 2 - console ownership.
    The order execution server dies about 45 seconds after launch if it does not
    own its console: its log shows "Signal Handler Activated: SIGINT" then
    "shutting down Order/Execution Server daemon". Any wrapper entrypoint - cmd
    /c, a PowerShell script, a supervisor - makes the engine a CHILD process,
    which is the shape that gets killed. Copying BEFORE start lets the entrypoint
    be the engine itself, so there is no parent console to lose.

    Config never enters an image layer, so a config-only change needs no rebuild.

    All the values below come from flow-plan-<role>.json - containerName,
    dockerNetwork, ip and serviceName - so nothing here is environment-specific
    and this file is safe to publish to the public bootstrap repo.

.EXAMPLE
    .\run-engine.ps1 -Name <containerName> `
        -Image <account>.dkr.ecr.<region>.amazonaws.com/flowtest/oe:<tag> `
        -ConfigDir C:\flowtest\staged\<serviceName> `
        -Network <dockerNetwork> -Ip <containerIp>

.EXAMPLE
    # Second engine sharing the first one's network namespace. Components that
    # are co-located on one production host share an address here too, which the
    # plan expresses by giving their group a single ip and sharedNamespace=true.
    .\run-engine.ps1 -Name <containerName2> -Image <...>/flowtest/oe-risk:<tag> `
        -ConfigDir C:\flowtest\staged\<serviceName2> `
        -NamespaceContainer <containerName1>
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [string] $Image,
    [Parameter(Mandatory)] [string] $ConfigDir,

    [string]   $Network,
    [string]   $Ip,
    [string]   $NamespaceContainer,
    [string]   $EngineHome = 'C:\engine',
    [string[]] $Args_,
    # Empty directories to create inside the container before it starts.
    # Plan-driven; see CONTAINER_REQUIRED_DIRS in the generator.
    [string[]] $RequiredEmptyDirs = @(),
    [switch]   $Replace,
    [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'

# Printed on every run. See the note in scripts/02-prereq-windows.ps1: without a
# version in the output a stale fetch is invisible, and a retest can silently
# re-run old code while looking like a fresh result.
$ScriptVersion = '2026-09-23.10-declared-bypasses'
Write-Host "  script version $ScriptVersion" -ForegroundColor DarkGray

function Write-Step { param([string] $m) Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string] $m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Warn { param([string] $m) Write-Host "  [warn] $m" -ForegroundColor Yellow }

# Native commands write to stderr for expected conditions - "No such container"
# when removing one that is not there. Under $ErrorActionPreference = 'Stop'
# PowerShell turns that into a TERMINATING error, which killed test-oe-console.ps1
# on its first real run. Same helper, same reason.
function Invoke-Docker {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $DockerArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & docker @DockerArgs 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
    }
    finally { $ErrorActionPreference = $prev }
}

if (-not (Test-Path $ConfigDir)) { throw "config directory not found: $ConfigDir" }
$configFiles = @(Get-ChildItem -Path $ConfigDir -File -Recurse)
if ($configFiles.Count -eq 0) {
    # Fail loudly rather than start an engine that will find no configuration and
    # behave as though it were misconfigured. This is the silent-success failure
    # mode this whole system specialises in.
    throw "config directory $ConfigDir is EMPTY. The engine would start, find no configuration where it expects it, and look misconfigured. Stage the config first."
}
Write-Ok "$($configFiles.Count) config file(s) in $ConfigDir"

# ---------------------------------------------------------------------------
# Network: either join an existing container's namespace (co-located engines
# sharing one production address) or attach to a network with a fixed address.
# Never both - '--network container:' takes the namespace wholesale, and adding
# --ip to it is rejected.
# ---------------------------------------------------------------------------
$netArgs = @()
if ($NamespaceContainer) {
    if ($Network -or $Ip) {
        throw "-NamespaceContainer cannot be combined with -Network/-Ip: joining another container's namespace takes its address too."
    }
    $netArgs = @('--network', "container:$NamespaceContainer")
    Write-Ok "sharing the network namespace of $NamespaceContainer"
} elseif ($Network) {
    $netArgs = @('--network', $Network)
    if ($Ip) { $netArgs += @('--ip', $Ip) }
    Write-Ok "network $Network$(if ($Ip) { " at $Ip" })"
} else {
    Write-Warn 'no network specified - the container will use the default network'
}

$existing = (docker ps -a --filter "name=^$Name$" --format '{{.Names}}') 2>$null
if ("$existing".Trim() -eq $Name) {
    if (-not $Replace) { throw "container '$Name' already exists. Pass -Replace to remove and recreate it." }
    Write-Warn "removing existing container $Name"
    if (-not $DryRun) { $null = Invoke-Docker rm -f $Name }
}

$createArgs = @('create', '--name', $Name) + $netArgs + @($Image) + $Args_

if ($DryRun) {
    Write-Step 'DRY RUN'
    Write-Host "  docker $($createArgs -join ' ')"
    Write-Host "  docker cp `"$ConfigDir\.`" ${Name}:$($EngineHome -replace '\\','/')/"
    Write-Host "  docker start $Name"
    return
}

# ---------------------------------------------------------------------------
Write-Step "create $Name"
$create = Invoke-Docker @createArgs
if ($create.ExitCode -ne 0) { throw "docker create failed for ${Name}: $($create.Output.Trim())" }
Write-Ok 'created (not started)'

Write-Step "copy config into $EngineHome"
# Trailing '\.' copies the CONTENTS of the directory, not the directory itself.
$target = ($EngineHome -replace '\\', '/').TrimEnd('/')
$cp = Invoke-Docker cp "$ConfigDir\." "${Name}:${target}/"
if ($cp.ExitCode -ne 0) {
    $null = Invoke-Docker rm -f $Name
    throw "docker cp failed for $Name - the container has been removed so it cannot start unconfigured"
}
Write-Ok "$($configFiles.Count) file(s) copied next to the binary"

# DIRECTORIES THE ENGINE NEEDS AND WILL NOT CREATE.
#
# Dev confirmed on 2026-09-23 that the OMS needs an EMPTY logs folder present
# before it starts and will not create one, so this creates it.
#
# IT IS NOT A FIX FOR THE SIGABRT. Build 121 created the folder and the RISK
# engine aborted identically, so that crash is something else. The earlier
# reading - that the g3log SinkWrapper frame at the top of the stack dump was
# the cause - was wrong: that frame is g3log's crash HANDLER unwinding, and
# the engine had already written its log file successfully. Do not let a
# familiar-looking frame stand in for a diagnosis; read the engine's own log,
# which is why 05-start-engines now copies it out on every failure.
#
# `docker cp` of an empty local directory is the only way in: the container is
# created and NOT started, so there is no process to exec into. Created empty
# and never populated - anything in it would be another run's history.
foreach ($d in @($RequiredEmptyDirs)) {
    if (-not $d) { continue }
    $stage = Join-Path $env:TEMP "flowtest-empty-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $stage -Force
    $mk = Invoke-Docker cp $stage "${Name}:${target}/${d}"
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    if ($mk.ExitCode -ne 0) {
        $null = Invoke-Docker rm -f $Name
        throw ("could not create the required directory ${target}/${d} in ${Name}: $($mk.Output.Trim()). " +
               'This engine family aborts at start-up without it, and the abort looks like an ' +
               'engine fault rather than a missing folder. The container has been removed.')
    }
    Write-Ok "created empty ${target}/${d}"
}

# READ IT BACK, because "docker cp returned 0" and "the engine can see these
# files" are different claims. On the Linux side the gap between them cost two
# builds - once a wrong target that produced a stray directory, once a copy
# that dropped a whole subtree - and in both the log said the configuration was
# in place. `docker cp` OUT needs no shell inside the image, so this works even
# on an engine image that has none. It is also what CONFIRMED the Windows
# engine home on build 110: reading C:/engine back returned the staged files
# alongside the binary and its libraries.
#
# NOTE ON THE MECHANISM: `docker cp <container>:<path> <dir>` copies OUT into a
# real directory. The tar-stream form ("- " as the destination) is not used
# here because PowerShell would have to capture binary on a pipeline that this
# script treats as text.
$script:ConfigReadback = 'unavailable'
$script:ConfigInContainer = @()
$readDir = Join-Path $env:TEMP "$Name-config-readback"
Remove-Item $readDir -Recurse -Force -ErrorAction SilentlyContinue
$null = New-Item -ItemType Directory -Path $readDir -Force
$read = Invoke-Docker cp "${Name}:${target}" $readDir
if ($read.ExitCode -eq 0) {
    # CONTAINMENT, NOT EQUALITY. Build 110 refused to start this hub because
    # C:/engine held 66 files against 13 staged - correct by the rule as
    # written, wrong in substance: on Windows the target IS the engine home,
    # so the binary and its libraries live there too. Only the Linux target is
    # a config-only directory. What must hold is that every staged path is
    # present; extra files are the image's own.
    #
    # Nothing is lost: a wrong target leaves 0 of 13 present, a dropped
    # subtree leaves 12 of 13, and both still refuse to start.
    $back = @(Get-ChildItem -Path $readDir -File -Recurse -ErrorAction SilentlyContinue)
    $prefix = [regex]::Escape($readDir) + '\\?'
    $rel = @($back | ForEach-Object { ($_.FullName -replace $prefix, '') -replace '\\', '/' })
    # docker cp OUT nests everything under the copied directory's own name.
    $inTarget = @{}
    foreach ($r in $rel) { $inTarget[($r -replace '^[^/]*/', '')] = $true }
    $script:ConfigInContainer = @($inTarget.Keys | Sort-Object)

    $stagedRel = @($configFiles | ForEach-Object {
        ($_.FullName.Substring($ConfigDir.Length).TrimStart('\')) -replace '\\', '/' })
    $missing = @($stagedRel | Where-Object { -not $inTarget.ContainsKey($_) } | Sort-Object)

    if ($missing.Count -eq 0) {
        $script:ConfigReadback = 'match'
        Write-Ok ("read back from the container: all $($stagedRel.Count) staged file(s) present " +
                  "under $target ($($back.Count) file(s) there in total)")
        $script:ConfigInContainer | Select-Object -First 40 | ForEach-Object { Write-Host "         $_" }
    } else {
        $script:ConfigReadback = 'mismatch'
        $present = $stagedRel.Count - $missing.Count
        Remove-Item $readDir -Recurse -Force -ErrorAction SilentlyContinue
        $null = Invoke-Docker rm -f $Name
        throw ("$Name - only $present of $($stagedRel.Count) staged file(s) reached ${target}. " +
               "MISSING: $($missing -join ', '). " +
               'The container has been removed rather than run on a partial configuration.')
    }
}
if ($script:ConfigReadback -eq 'unavailable') {
    Write-Warn "could not read $target back out of $Name; this run cannot prove the engine sees the staged files"
}
Remove-Item $readDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Step "start $Name"
$start = Invoke-Docker start $Name
if ($start.ExitCode -ne 0) { throw "docker start failed for ${Name}: $($start.Output.Trim())" }

Start-Sleep -Seconds 3
$state = (Invoke-Docker inspect -f '{{.State.Status}}' $Name).Output.Trim()
if ("$state".Trim() -ne 'running') {
    Write-Warn "container is '$state' three seconds after start. Last output:"
    # Invoke-Docker, not a bare call. A container's own stderr comes back on
    # stderr, so under EAP=Stop this line threw instead of printing the logs -
    # losing exactly the diagnostic it exists to show, at the moment an engine
    # failed to stay up. Every other docker call in this file already routes
    # through the helper; this one was missed.
    $logs = (Invoke-Docker logs --tail 30 $Name).Output
    if ($logs) { foreach ($line in ($logs.TrimEnd() -split "`r?`n")) { Write-Host "    $line" } }
    else { Write-Warn 'the container produced no output at all.' }
    throw "$Name did not stay running"
}
Write-Ok "running as $((Invoke-Docker inspect -f '{{.Config.Entrypoint}}' $Name).Output.Trim())"

Write-Host ''
Write-Host 'Note: the ~45s console death does NOT reproduce in this runtime - probed 2026-08-31,'
Write-Host 'handler registered and no event delivered in 120s across four container shapes. But'
Write-Host 'that measured the runtime, not this engine, and three seconds of uptime proves nothing'
Write-Host "either way. Check again in two minutes:  docker ps --filter name=$Name"
