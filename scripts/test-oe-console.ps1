<#
.SYNOPSIS
    Does a Windows container deliver console control events to its entrypoint?

.DESCRIPTION
    The order execution server dies about 45 seconds after launch if it does not
    own its console. Its log shows
        Signal Handler Activated: SIGINT
        shutting down Order/Execution Server daemon
    The FIX engines ignore the same interrupt and survive, which is why this
    looked for days like an OE configuration fault rather than a launch fault.

    Three detached launch methods were already tried on the HOST and all failed:
        Start-Process   killed by the console interrupt when the parent closes
        nohup           HARD FAULT inside the market-data client
        cmd /c start    exits after a few seconds
    Only a foreground interactive session worked.

    In a container the engine is the entrypoint process with no interactive
    console at all. Whether it survives that is unverified, and 6 of our 12
    images are order-execution-server family.

    TWO MODES

    -Mode probe   (default, and the one to run first)
        Builds and runs a small console application that registers a real Win32
        console control handler and reports what arrives. Needs NO engine image,
        NO staged config and NO flow-test stack - just a Server 2022 host with
        Docker. That matters, because the console question is a property of the
        RUNTIME, and making it wait for artifact staging would leave the highest
        risk in the project untested for weeks.

    -Mode image -Image <ref> -ConfigDir <dir>
        The real thing, once an OE image and its config exist. Same four console
        shapes, same reporting.

    FOUR CONSOLE SHAPES, because they differ in exactly the way that matters:
        detached          no TTY, no stdin   - the default, most likely to reproduce
        detached+tty      pseudo-console     - closest to "owns its console"
        detached+stdin    stdin held open    - stops console teardown on exit
        detached+both     -i -t

.EXAMPLE
    .\test-oe-console.ps1
    # probe mode - answers the runtime question today

.EXAMPLE
    .\test-oe-console.ps1 -Mode image -Image <ecr>/flowtest/oe:v9.1.7.11 `
        -ConfigDir C:\flowtest\staged\<engine-folder>
#>

[CmdletBinding()]
param(
    [ValidateSet('probe', 'image')]
    [string] $Mode = 'probe',

    [string] $Image,
    [string] $ConfigDir,
    [string] $EngineHome = 'C:\engine',

    [int]    $WatchSeconds = 120,
    [int]    $PollSeconds  = 10,
    [string] $NamePrefix   = 'oe-console-test',
    [switch] $KeepContainers
)

$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $m) Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok   { param([string] $m) Write-Host "  [ok]   $m" -ForegroundColor Green }
function Write-Bad  { param([string] $m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-Warn { param([string] $m) Write-Host "  [warn] $m" -ForegroundColor Yellow }

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------------------
Write-Step 'Preflight'

# Same PATH reasoning as build-images.ps1: this may be invoked through
# ssm send-command, whose shell inherits the SSM Agent's environment.
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    $dockerDir = 'C:\Program Files\Docker'
    if (Test-Path (Join-Path $dockerDir 'docker.exe')) {
        $env:Path = "$env:Path;$dockerDir"
        Write-Warn "docker was not on PATH; using $dockerDir for this session"
    } else {
        throw 'docker not found. Run 02-prereq-windows.ps1 first.'
    }
}
Write-Ok "docker: $((docker --version) 2>&1)"

$info = (docker info --format '{{.OSType}}') 2>&1
if ("$info".Trim() -ne 'windows') {
    throw "the Docker daemon is in '$info' mode, not windows."
}
Write-Ok 'daemon is in Windows container mode'

$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
if ($build -eq 20348) { Write-Ok "host build $build - matches servercore:ltsc2022" }
else { Write-Warn "host build $build is NOT 20348; the base image tag must match or nothing will run" }

# ---------------------------------------------------------------------------
# Work out what we are testing.
# ---------------------------------------------------------------------------
$copyConfig = $false

if ($Mode -eq 'probe') {
    Write-Step 'Building the console probe'
    $context = Join-Path $ScriptRoot 'console-probe'
    if (-not (Test-Path (Join-Path $context 'Dockerfile'))) {
        throw "console-probe/Dockerfile not found under $ScriptRoot"
    }
    $Image = 'flowtest-console-probe:local'
    docker build --file (Join-Path $context 'Dockerfile') --tag $Image $context
    if ($LASTEXITCODE -ne 0) { throw 'failed to build the console probe image' }
    Write-Ok "built $Image"
    Write-Host '  No engine image, no staged config and no stack are involved - this'
    Write-Host '  measures the RUNTIME, which is what the question is actually about.'
}
else {
    if (-not $Image)     { throw '-Mode image requires -Image' }
    if (-not $ConfigDir) { throw '-Mode image requires -ConfigDir' }
    if (-not (Test-Path $ConfigDir)) { throw "config directory not found: $ConfigDir" }
    $configCount = @(Get-ChildItem -Path $ConfigDir -File -Recurse).Count
    if ($configCount -eq 0) {
        throw "config directory $ConfigDir is EMPTY. Without config the engine may exit for a completely different reason and the test would prove nothing."
    }
    Write-Ok "config: $ConfigDir ($configCount files)"
    $copyConfig = $true
}

$variants = @(
    @{ Key = 'detached';       Flags = @();           Note = 'no TTY, no stdin - the default shape' },
    @{ Key = 'detached+tty';   Flags = @('-t');       Note = 'pseudo-console attached' },
    @{ Key = 'detached+stdin'; Flags = @('-i');       Note = 'stdin held open' },
    @{ Key = 'detached+both';  Flags = @('-i', '-t'); Note = 'stdin and pseudo-console' }
)

$results = New-Object System.Collections.ArrayList
$target  = ($EngineHome -replace '\\', '/').TrimEnd('/')

Write-Step 'Under test'
Write-Host "  mode    : $Mode"
Write-Host "  image   : $Image"
Write-Host "  watching: $WatchSeconds seconds per variant"

foreach ($v in $variants) {
    $name = "$NamePrefix-$($v.Key -replace '\+','-')"
    Write-Step "$($v.Key)  ($($v.Note))"

    docker rm -f $name 2>&1 | Out-Null

    $createArgs = @('create', '--name', $name) + $v.Flags + @($Image)
    docker @createArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Bad 'docker create failed'; continue }

    # Engine images need config delivered before start - see run-engine.ps1.
    # The probe carries everything it needs.
    if ($copyConfig) {
        docker cp "$ConfigDir\." "${name}:${target}/" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Bad 'docker cp failed'; docker rm -f $name | Out-Null; continue }
    }

    $started = Get-Date
    docker start $name | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Bad 'docker start failed'; docker rm -f $name | Out-Null; continue }

    $died = $null
    $elapsed = 0
    while ($elapsed -lt $WatchSeconds) {
        Start-Sleep -Seconds $PollSeconds
        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        $state = "$((docker inspect -f '{{.State.Status}}' $name) 2>&1)".Trim()
        if ($state -ne 'running') {
            $died = $elapsed
            Write-Bad "stopped after ~${elapsed}s (state: $state)"
            break
        }
        Write-Host "    ${elapsed}s: running"
    }

    $exitCode = "$((docker inspect -f '{{.State.ExitCode}}' $name) 2>&1)".Trim()
    $logs     = "$((docker logs --tail 60 $name) 2>&1)"

    # Two signatures. The probe reports the control event by name; the real
    # engine reports its own. Finding either is the difference between "the
    # console constraint reproduced" and "something else broke".
    $probeEvent  = [regex]::Match($logs, 'CONSOLE_EVENT (\S+) at (\d+)s')
    $engineEvent = $logs -match 'Signal Handler Activated'
    $shutdown    = $logs -match 'shutting down'

    if (-not $died) { Write-Ok "still running after ${WatchSeconds}s" }
    if ($probeEvent.Success) {
        Write-Warn "console event $($probeEvent.Groups[1].Value) delivered at $($probeEvent.Groups[2].Value)s"
    }
    if ($engineEvent) { Write-Warn 'log contains "Signal Handler Activated" - the console interrupt reached the engine' }
    if ($shutdown)    { Write-Warn 'log contains "shutting down" - it terminated itself, it was not killed' }

    $null = $results.Add([pscustomobject]@{
        Variant    = $v.Key
        Survived   = (-not $died)
        DiedAtSec  = if ($died) { $died } else { '-' }
        ExitCode   = if ($died) { $exitCode } else { '-' }
        ConsoleEvt = if ($probeEvent.Success) { $probeEvent.Groups[1].Value } elseif ($engineEvent) { 'SIGINT' } else { 'none' }
    })

    if (-not $KeepContainers) { docker rm -f $name 2>&1 | Out-Null }
    else { Write-Warn "kept container $name for inspection" }
}

Write-Host ''
Write-Host '=== results ===' -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host

$survivors = @($results | Where-Object { $_.Survived })
$anyEvent  = @($results | Where-Object { $_.ConsoleEvt -ne 'none' })

if ($survivors.Count -eq $results.Count -and $anyEvent.Count -eq 0) {
    Write-Ok "every variant survived ${WatchSeconds}s and no console event was delivered"
    Write-Host ''
    Write-Host 'What this means:'
    Write-Host '  The container runtime does not send console control events unprompted.'
    Write-Host '  The order execution server dying at ~45s on the HOST was the parent'
    Write-Host '  console going away - and a container does not have one to lose.'
    Write-Host ''
    if ($Mode -eq 'probe') {
        Write-Host '  This is strong evidence, not proof for the engine itself. Re-run with'
        Write-Host '  -Mode image once an OE image and its config exist, and use the SIMPLEST'
        Write-Host '  variant: plain detached, no -i, no -t.'
    }
    exit 0
}

if ($survivors.Count -eq 0 -and $anyEvent.Count -eq 0) {
    # Everything died and NOTHING delivered a console event. Console handling
    # was never involved, so the console advice below would send someone down
    # entirely the wrong path - which is the failure mode this whole exercise
    # exists to avoid.
    Write-Bad 'No variant survived, and no console event was delivered to any of them.'
    Write-Host ''
    Write-Host 'This is NOT the console constraint. The process is dying for another reason.'
    Write-Host 'Look at the container logs above: in probe mode the likely causes are the'
    Write-Host 'base image tag not matching the host build, or the image failing to start at'
    Write-Host 'all. In image mode, add missing config or a missing runtime dependency to'
    Write-Host 'the list. Re-run with -KeepContainers and inspect:'
    Write-Host "    docker logs $NamePrefix-detached"
    exit 1
}

if ($survivors.Count -eq 0) {
    Write-Bad 'No variant survived, and a console event was delivered - the constraint reproduces.'
    Write-Host ''
    Write-Host 'Next candidates, in order of cost:'
    Write-Host '  1. docker run --sig-proxy=false     stops the client forwarding signals'
    Write-Host '  2. run the engine as a Windows service inside the container, so it owns a'
    Write-Host '     service context rather than a console. Costs the clean one-process-per-'
    Write-Host '     container shape, so only if 1 fails.'
    Write-Host '  3. ask Dev whether the engine can ignore console control events - the FIX'
    Write-Host '     engines already do, so the handling exists in the codebase.'
    Write-Host ''
    Write-Host 'Do NOT let a flow depend on an OE image until this is resolved. In a flow it'
    Write-Host 'would present as a networking or config fault, which is what cost Dev days.'
    exit 1
}

Write-Warn "$($survivors.Count) of $($results.Count) variant(s) survived"
Write-Host ''
Write-Host 'Use the simplest surviving variant in run-engine.ps1. If only a TTY variant'
Write-Host 'survived, that is worth telling Dev: it means the engine genuinely requires a'
Write-Host 'console, which constrains how it can ever be hosted, not just containerised.'
exit 0
