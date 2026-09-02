<#
    01-bootstrap-windows.ps1 - the second half of the Windows bootstrap.

    WHY THIS FILE EXISTS

    EC2 caps UserData at 16 KiB after base64 encoding. That is a hard AWS limit,
    not a soft one. With the whole bootstrap inline the Windows UserData reached
    92% for HANW - about 1.3 KB of headroom - and the generator warned on every
    run. Trimming the flow plan was measured and does not help: the plan is only
    13-19% of the payload, and gzip already collapses its repetition, so the
    surgical trim saved 116 bytes. The bootstrap SCRIPT was the weight.

    The second reason matters more day to day. The reboot / marker / resume logic
    below has been wrong three times, and while it lived in UserData every fix
    cost a template regeneration and a fresh stack. Here it is an ordinary file
    in the tooling repo, so a fix is a git push and a re-run - the same cheap
    loop the prereq script already enjoys.

    THE SPLIT

    UserData keeps only what must happen BEFORE this file can exist on the host:
      1. write the embedded flow plan
      2. deprioritise the prod NICs so egress works
      3. wait for egress
      4. resolve the GitHub token, fetch and extract the tooling tarball
      5. run this script

    Everything after the handoff lives here: the FAILED marker, running the
    prereq script, interpreting its exit code, and writing READY.

    WHY USERDATA RESTARTS THE SSM AGENT (step 1d), AND WHY IT IS NOT COSMETIC

    Build 59 failed with "windows host never registered with SSM" while the
    Linux host registered normally. It is a RACE, not a permanent fault:

      boot            The SSM Agent starts. DHCP may have handed a prod NIC a
                      default route that beats the management NIC - and the
                      prod-mirroring subnets have no route to the internet by
                      design, so that route is a blackhole.
      agent           Cannot reach the SSM endpoints. Enters retry backoff.
      UserData 1b     Removes the blackhole routes. Egress now works.
      nothing         Restarts the agent, so it waits out its own backoff.
      Jenkins gate 2  Times out, and the build fails on a host that would have
                      registered a few minutes later.

    The prod NICs sometimes come up with NO default route at all - we have
    logged both outcomes on the same flow - which is why earlier builds passed.
    We were winning the race, not avoiding it.

    The prereq script only WARNED about this. Its own restart, in
    Sync-ServiceEnvironment, runs much later and only when the PATH changed, so
    it cannot help a readiness gate that has already given up. Restarting in
    UserData the moment egress is confirmed costs about two seconds.

    THE READY / FAILED CONTRACT

    The pipeline polls for two marker files and nothing else:
      READY   written ONLY when the host is genuinely usable
      FAILED  written the moment bootstrap cannot succeed

    Both halves matter. Without FAILED, a failed bootstrap is indistinguishable
    from a slow one and the pipeline waits out a 25-minute timeout for a failure
    that already happened - build 49 spent 25 minutes exactly that way. And READY
    must never be written optimistically: an earlier version wrote it after a
    reboot-pending exit, so the gates passed on a host with no container runtime
    at all.
#>

param(
    [Parameter(Mandatory = $true)] [string] $Root,
    [Parameter(Mandatory = $true)] [string] $PlanFile,
    [string] $ReadyMarker
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Printed first, every run. See the note in 02-prereq-windows.ps1: without this
# a stale fetch is invisible, and a retest can silently re-run old code.
$ScriptVersion = '2026-09-02.1-curl-config-paths'
Write-Host "bootstrap script version $ScriptVersion"

if (-not $ReadyMarker) { $ReadyMarker = Join-Path $Root 'READY' }
$failedMarker = Join-Path $Root 'FAILED'
$prereqLog    = Join-Path $Root 'prereq.log'
$userDataLog  = Join-Path $Root 'userdata.log'

function Write-BootstrapFailure {
    param([string] $Reason)
    try {
        # Prefer the PREREQ log. When the prereq script fails, its own output is
        # the reason; userdata.log holds only the bootstrap's lines, which stop
        # at "running <script>" and say nothing about why it exited. Build 55
        # failed exactly this way and the marker could only report "exit code 1".
        $logPath = if (Test-Path $prereqLog) { $prereqLog } else { $userDataLog }
        $tail = (Get-Content $logPath -Tail 25 -ErrorAction SilentlyContinue) -join [Environment]::NewLine
        Set-Content -Path $failedMarker -Value (
            "$Reason at $(Get-Date -Format o)" + [Environment]::NewLine +
            "--- last 25 lines of $(Split-Path -Leaf $logPath) ---" + [Environment]::NewLine + $tail)
    } catch { }
}

try {
    if (Test-Path $ReadyMarker) {
        Write-Host 'already bootstrapped; nothing to do'
        exit 0
    }

    $prereq = Get-ChildItem -Path $Root -Recurse -Filter '02-prereq-windows.ps1' -ErrorAction SilentlyContinue |
              Select-Object -First 1
    if (-not $prereq) { throw '02-prereq-windows.ps1 not found under the tooling archive' }
    Write-Host "running $($prereq.FullName)"

    # Tee the child's output to its OWN log. Start-Transcript records the calling
    # session and does NOT capture a child started with & powershell.exe, so
    # without this the prereq script's output goes nowhere and a failure reports
    # only its exit code.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $prereq.FullName `
        -PlanFile $PlanFile -ReadyMarker $ReadyMarker `
        *>&1 | Tee-Object -FilePath $prereqLog -Append
    $code = $LASTEXITCODE

    if ($code -eq 3010) {
        # 3010 = "success, reboot required". The prereq script has registered its
        # own RunOnce resume and is restarting the host; it writes READY itself
        # once it truly finishes. NOT a failure, and emphatically not ready - so
        # write neither marker and let the pipeline keep polling.
        Write-Host 'BOOTSTRAP PAUSED: rebooting to activate the container platform'
        exit 3010
    }

    if ($code -eq 0) {
        # The prereq script writes READY itself after its own verification pass.
        # Write it here too only if it did not, so the contract holds either way.
        if (-not (Test-Path $ReadyMarker)) {
            Set-Content -Path $ReadyMarker -Value (Get-Date -Format o)
        }
        Remove-Item -Path $failedMarker -Force -ErrorAction SilentlyContinue
        Write-Host 'BOOTSTRAP COMPLETE'
        exit 0
    }

    Write-BootstrapFailure "exit code $code"
    Write-Host "BOOTSTRAP FAILED with exit code $code"
    exit $code
}
catch {
    Write-BootstrapFailure $_.Exception.Message
    Write-Host "BOOTSTRAP FAILED: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    exit 1
}
