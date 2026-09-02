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
    [switch]   $Replace,
    [switch]   $DryRun
)

$ErrorActionPreference = 'Stop'

# Printed on every run. See the note in scripts/02-prereq-windows.ps1: without a
# version in the output a stale fetch is invisible, and a retest can silently
# re-run old code while looking like a fresh result.
$ScriptVersion = '2026-09-01.2-buildimages-routerepeat'
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

Write-Step "start $Name"
$start = Invoke-Docker start $Name
if ($start.ExitCode -ne 0) { throw "docker start failed for ${Name}: $($start.Output.Trim())" }

Start-Sleep -Seconds 3
$state = (Invoke-Docker inspect -f '{{.State.Status}}' $Name).Output.Trim()
if ("$state".Trim() -ne 'running') {
    Write-Warn "container is '$state' three seconds after start. Last output:"
    docker logs --tail 30 $Name
    throw "$Name did not stay running"
}
Write-Ok "running as $((Invoke-Docker inspect -f '{{.Config.Entrypoint}}' $Name).Output.Trim())"

Write-Host ''
Write-Host 'Note: the ~45s console death does NOT reproduce in this runtime - probed 2026-08-31,'
Write-Host 'handler registered and no event delivered in 120s across four container shapes. But'
Write-Host 'that measured the runtime, not this engine, and three seconds of uptime proves nothing'
Write-Host "either way. Check again in two minutes:  docker ps --filter name=$Name"
