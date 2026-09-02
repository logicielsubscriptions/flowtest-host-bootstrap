<#
.SYNOPSIS
    Prerequisite installation for a Windows container host that runs containers
    on caller-specified static IPs.

.DESCRIPTION
    Prepares a Windows Server 2022 EC2 instance to host Windows containers whose
    addresses are dictated by a plan file (see -PlanFile). This script is
    deliberately generic: it declares no addresses, hostnames or workloads of its
    own - everything comes from the plan.

    Installs, in order:
        Containers feature (+ optional Hyper-V for isolated containers)
        Mirantis Container Runtime (MCR) - the supported Docker runtime on
          Windows Server; Docker CE is not available for Windows Server
        Chocolatey, git, AWS CLI v2, OpenJDK 17 (Jenkins agent)
        Microsoft ODBC Driver 18 for SQL Server + sqlcmd (mssql-tools18)
        HNS PowerShell module
        servercore:ltsc2022 base image
        l2bridge Docker networks bound to eth1 / eth2

    IP-exactness note: l2bridge is used rather than 'transparent' because
    l2bridge rewrites container MAC addresses to the host NIC's MAC. EC2
    filters foreign MACs, so transparent/macvlan-style networks fail there
    while l2bridge works.

.PARAMETER PlanFile
    Path to the flow-plan-windows.json produced by generator/generate_cfn.py.
    Nothing about the flow is hardcoded in this script - networks, container
    addresses and peers all come from the plan. Instance UserData passes this in
    automatically; supply it by hand only when re-running manually.

.PARAMETER SkipReboot
    Do not reboot automatically after enabling the Containers feature.

.PARAMETER SkipNetworks
    Skip Docker network creation (useful on a first pass before the secondary
    ENIs are visible inside the OS).

.NOTES
    Run in an elevated PowerShell session.
    CloudFormation now creates the ENIs, assigns the exact production addresses
    as secondary private IPs, and disables source/dest check - so no AWS-side
    preparation is needed here.
    Expect ONE reboot: re-run the script after it, it is idempotent and will
    continue where it left off. Instance UserData uses <persist>true</persist>,
    so on a CloudFormation-launched host the re-run happens automatically.
#>

[CmdletBinding()]
param(
    [string]$PlanFile,
    # Written by this script when it genuinely finishes. Passed by the bootstrap
    # so that a run which needs a reboot can resume and STILL satisfy the
    # readiness contract - see the reboot handling in Enable-ContainerFeatures.
    [string]$ReadyMarker,

    [switch]$SkipReboot,
    [switch]$SkipNetworks,

    # Run ONLY the route-priority fix and exit. This is what the boot-triggered
    # scheduled task invokes: the prod-NIC default routes come back from DHCP on
    # every reboot, and UserData runs once per instance, so without a task at
    # boot a host that reboots on day three silently loses egress.
    [switch]$RoutesOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# PRINTED FIRST, ON EVERY RUN. Bump it with every published change.
#
# Four host-side retests were run without this, and one of them produced output
# byte-identical to the previous run because the repo had not been republished -
# a stale fetch is invisible when nothing in the output identifies the code. The
# whole round was spent re-diagnosing fixes that were never on the host.
#
# The same lesson as PIPELINE_VERSION in Jenkinsfile-generate-cfn, which was
# itself once left un-bumped so a build reported a version that did not describe
# the code it ran. Cheap marker, expensive absence.
$script:ScriptVersion = '2026-09-01.2-buildimages-routerepeat'

# ----------------------------- configuration -----------------------------

# Host-level constants only. Everything flow-specific comes from $PlanFile.
$script:Config = @{
    BaseImage      = 'mcr.microsoft.com/windows/servercore:ltsc2022'
    JdkPackage     = 'openjdk17'
    McrInstallUrl  = 'https://get.mirantis.com/install.ps1'
    # DO NOT TRUST A FWLINK ID BECAUSE IT USED TO WORK. Microsoft RECYCLES them.
    #
    # linkid=2280795 was the mssql-tools18 x64 installer. As of 2026-09-01 it
    # 302s to a Microsoft Learn RSS feed for an unrelated product
    # (dynamics365-remote-assist-242) and returns 873 bytes of XML. The host
    # downloaded that 873-byte file, handed it to msiexec, and got exit 1620
    # (ERROR_INSTALL_PACKAGE_INVALID) - which reads as "corrupt download" and
    # sends you looking at the transfer instead of the URL. Two retries produced
    # the same 873 bytes, which is what proved it was not truncation.
    #
    # Both IDs below were verified on 2026-09-01 to return real MSIs whose
    # Subject matches the expected product. If sqlcmd starts failing again, check
    # what the fwlink actually resolves to BEFORE assuming a network fault:
    #   curl -sSL -o /tmp/x -w '%{url_effective} %{size_download}\n' <fwlink>
    # Current source of truth:
    # learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-download-install
    OdbcUrl        = 'https://go.microsoft.com/fwlink/?linkid=2280794'   # msodbcsql18 x64, verified
    MsSqlToolsUrl  = 'https://go.microsoft.com/fwlink/?linkid=2370127'   # cmd line utils 17.0.4055.5 x64, verified
    WorkRoot       = 'C:\FlowTest'
}

# Populated by Import-FlowPlan.
$script:Plan = $null

function Import-FlowPlan {
    Write-Step 'Flow plan'

    if (-not $PlanFile) {
        $default = Join-Path $Config.WorkRoot 'bootstrap\flow-plan-windows.json'
        if (Test-Path $default) {
            $PlanFile = $default
            Write-Host "  no -PlanFile given; using $default"
        }
    }

    if (-not $PlanFile -or -not (Test-Path $PlanFile)) {
        Write-Warn 'no flow plan found - installing tooling only, skipping Docker networks'
        Write-Warn 'Generate one with: python3 generator/generate_cfn.py --flow <FLOW> ...'
        $script:Plan = $null
        return
    }

    $script:Plan = Get-Content -Raw -Path $PlanFile | ConvertFrom-Json

    if ($Plan.hostRole -ne 'windows') {
        throw "plan file is for hostRole '$($Plan.hostRole)', not 'windows'. Wrong plan file?"
    }
    if ($Plan.workRoot) { $Config.WorkRoot = $Plan.workRoot }

    Write-Ok "flow: $($Plan.flow)"
    foreach ($network in $Plan.networks) {
        Write-Ok ("{0}  {1}  host={2}  containers={3}" -f `
            $network.dockerNetwork, $network.subnetCidr, $network.hostPrimaryIp, ($network.containerIps -join ', '))
    }
    foreach ($group in $Plan.groups) {
        $services = ($group.services | ForEach-Object { $_.serviceName }) -join ', '
        $shared = if ($group.sharedNamespace) { " [shared namespace via $($group.namespaceContainer)]" } else { '' }
        Write-Ok "group $($group.prodHost) @ $($group.ip): $services$shared"
    }
}

# ----------------------------- helpers -----------------------------

function Write-Step { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "  [ok]   $Message" -ForegroundColor Green }
function Write-Skip { param([string]$Message) Write-Host "  [skip] $Message" -ForegroundColor DarkGray }
function Write-Warn { param([string]$Message) Write-Host "  [warn] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

function Assert-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated PowerShell session.'
    }
}

function Assert-SupportedOs {
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Ok "OS: $($os.Caption) (build $($os.BuildNumber))"
    if ($os.ProductType -eq 1) {
        throw "This host is a client OS. Windows Server 2019/2022 is required for the FIX/OE containers."
    }
    if ([int]$os.BuildNumber -lt 17763) {
        throw "Build $($os.BuildNumber) is too old. Windows Server 2019 (17763) or later is required."
    }
    if ([int]$os.BuildNumber -lt 20348) {
        Write-Warn "Not Server 2022 (20348). Change BaseImage to servercore:ltsc2019 - Windows container images must match the host kernel."
    }
}

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-CommandVersion {
    <#
        ONE definition of "does this tool work", returning both the verdict and
        what the tool said. Everything that asks the question uses this.

        It exists because two different implementations disagreed on the same
        host: the installer path used Get-Command (satisfied by a Chocolatey
        shim) and skipped its own fix, while the verification pass invoked the
        tool inside a scriptblock under $ErrorActionPreference='Stop' and
        reported it unavailable. Under PS 5.1 any native stderr becomes a
        terminating ErrorRecord when EAP is 'Stop', and `java -version` writes
        its banner to stderr - so a working java can be reported as missing.
        Dropping to 'Continue' for the call removes that whole class of error.
    #>
    param(
        [string] $Name,
        [string[]] $Arguments = @()
    )
    if (-not (Test-CommandExists $Name)) {
        return [pscustomobject]@{ Ok = $false; Text = 'not found on PATH'; Exit = $null }
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out  = & $Name @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
        $first = ($out.Trim() -split "`r?`n" | Select-Object -First 1)
        # Some tools report a version and exit non-zero (usage screens do this).
        # Treat "said something" as working and record the code for the log.
        return [pscustomobject]@{ Ok = [bool]($out.Trim()); Text = $first; Exit = $code }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Text = $_.Exception.Message; Exit = $null }
    }
    finally { $ErrorActionPreference = $prev }
}

function Test-CommandRuns {
    <#
        RESOLVING is not the same as WORKING, and the difference cost a run.

        Chocolatey leaves shims in C:\ProgramData\chocolatey\bin, which is on the
        machine PATH. After its openjdk17 package installed, `Get-Command java`
        succeeded - so the PATH fallback below decided there was nothing to fix -
        while the verification pass, which actually runs `java -version`, reported
        java unavailable. Two checks for the same fact, disagreeing, and the
        weaker one gating the fix for the stronger one.

        This runs the command and requires it to exit 0 AND say something. Native
        tools often write their version banner to stderr (java does), so 2>&1 is
        required, and $ErrorActionPreference must drop to Continue for the call:
        under 'Stop', PS 5.1 turns any native stderr into a terminating error.
    #>
    param(
        [string] $Name,
        [string[]] $Arguments = @()
    )
    if (-not (Test-CommandExists $Name)) { return $false }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Name @Arguments 2>&1 | Out-String
        return [bool]($LASTEXITCODE -eq 0 -and $out.Trim())
    }
    catch { return $false }
    finally { $ErrorActionPreference = $prev }
}

function Add-MachinePathEntry {
    <#
        Add a directory to the MACHINE PATH, persistently and idempotently, and
        make it usable in this session too.

        Three traps this avoids:

        1. [Environment]::SetEnvironmentVariable('Path', ..., 'Machine') rewrites
           the value as REG_SZ. The real machine PATH is REG_EXPAND_SZ and holds
           entries like %SystemRoot%\system32 - converting it stops those
           expanding and leaves the box with a subtly broken PATH. We write the
           registry value directly and keep its original kind.

        2. Substring matching. "*C:\Program Files\Docker*" also matches
           "C:\Program Files\Docker Nested", so entries are compared one at a
           time: trimmed, case-insensitive, ignoring a trailing backslash.

        3. Reading the value with Get-ItemProperty EXPANDS it, so writing it back
           would bake today's expansion in permanently. We read it raw.
    #>
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [string] $Label = 'directory'
    )

    if (-not (Test-Path $Directory)) {
        Write-Warn "$Label not added to PATH: $Directory does not exist"
        return $false
    }

    $normalize = { param($p) $p.Trim().TrimEnd('\').ToLowerInvariant() }
    $target = & $normalize $Directory

    $key  = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
    $item = Get-Item -Path $key
    $raw  = $item.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $kind = $item.GetValueKind('Path')

    $entries = @($raw -split ';' | Where-Object { $_.Trim() -ne '' })
    foreach ($entry in $entries) {
        if ((& $normalize $entry) -eq $target) {
            Write-Skip "$Label already on the machine PATH"
            # Still make sure THIS session can see it.
            if (($env:Path -split ';' | ForEach-Object { & $normalize $_ }) -notcontains $target) {
                $env:Path = "$env:Path;$Directory"
            }
            return $false
        }
    }

    $new = ($entries + $Directory) -join ';'
    Set-ItemProperty -Path $key -Name 'Path' -Value $new -Type $kind
    $env:Path = "$env:Path;$Directory"
    Write-Ok "$Label added to the machine PATH: $Directory"
    return $true
}

function Sync-ServiceEnvironment {
    <#
        A machine PATH change does not reach processes that are already running,
        and that includes the SSM Agent service. Anything the pipeline later runs
        through ssm send-command inherits the AGENT's environment, captured when
        the agent started - so without this, docker is on the PATH for an
        interactive session but NOT for a remote command. That half-working state
        is far more confusing than a clean failure.

        Restarting the agent makes it re-read the environment. A reboot does the
        same, and this script asks for one anyway after enabling the container
        features; this just means remote commands work before that reboot.
    #>
    $svc = Get-Service -Name 'AmazonSSMAgent' -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Skip 'SSM Agent not present; nothing to refresh'; return }
    try {
        Restart-Service -Name 'AmazonSSMAgent' -Force -ErrorAction Stop
        Write-Ok 'SSM Agent restarted so remote commands inherit the new PATH'
    } catch {
        Write-Warn "could not restart the SSM Agent: $($_.Exception.Message)"
        Write-Warn 'Remote commands may not see the new PATH until this host reboots.'
    }
}

function Invoke-Download {
    param([string]$Uri, [string]$OutFile)
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing
}

function Install-MsiFromUrl {
    param(
        [string]$Uri,
        [string]$FileName,
        [string]$DisplayName,
        [string[]]$ExtraArgs = @()
    )
    $installer = Join-Path $env:TEMP $FileName

    # RETRY, because the observed failure was a bad DOWNLOAD, not a bad package.
    #
    # mssql-tools18 failed on a real host with msiexec exit code 1620,
    # ERROR_INSTALL_PACKAGE_INVALID - "this installation package could not be
    # opened". That is what a truncated or corrupted file looks like, and the
    # original code reported it as an installation failure and moved on, which
    # sends you looking at the package instead of the transfer.
    #
    # An MSI that did not finish downloading is also usually implausibly small,
    # so check the size before handing it to msiexec and say so plainly.
    $minBytes = 100KB
    $attempts = 2
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
        if ($attempt -eq 1) { Write-Host "  downloading $DisplayName ..." }
        else                { Write-Warn "  re-downloading $DisplayName (attempt $attempt of $attempts) ..." }
        Invoke-Download -Uri $Uri -OutFile $installer

        # Test-Path first: if the download produced nothing at all, Get-Item
        # returns $null and dotting .Length off it throws under StrictMode -
        # aborting the script for what is meant to be a HANDLED failure, which
        # would defeat the retry immediately below.
        $size = if (Test-Path $installer) { (Get-Item $installer).Length } else { 0 }

        # CHECK WHAT THE FILE ACTUALLY IS, not just how big it is.
        #
        # An MSI is an OLE compound document and always starts D0 CF 11 E0. A
        # recycled fwlink hands back an HTML or XML error page instead, and the
        # size check alone reported that as "too small", which reads as a
        # truncated transfer and invites a retry that cannot help. Retrying a
        # wrong URL is just doing the wrong thing twice: linkid 2280795 returned
        # the same 873-byte RSS feed on both attempts.
        $isMsi = $false
        $head  = ''
        if ($size -ge 8) {
            $bytes = [IO.File]::ReadAllBytes($installer)[0..7]
            $isMsi = ($bytes[0] -eq 0xD0 -and $bytes[1] -eq 0xCF -and $bytes[2] -eq 0x11 -and $bytes[3] -eq 0xE0)
            if (-not $isMsi) {
                try { $head = ([IO.File]::ReadAllText($installer)).Substring(0, [Math]::Min(160, $size)) } catch { }
            }
        }

        if (-not $isMsi) {
            if ($head -match '(?i)<\?xml|<html|<rss|<!DOCTYPE') {
                # Unambiguous: the URL is serving a web page. Do not retry.
                Write-Fail "  the download URL returned a web page, not an MSI ($size bytes)."
                Write-Warn  "  $($head -replace '\s+', ' ')"
                throw ("$DisplayName URL does not serve an installer. Check where it redirects - " +
                       'Microsoft recycles fwlink ids onto unrelated products. See the Config block.')
            }
            Write-Warn "  downloaded $size bytes that are not a valid MSI (bad magic bytes)"
            if ($attempt -lt $attempts) { continue }
            throw "$DisplayName download produced a $size byte non-MSI file after $attempts attempts."
        }

        if ($size -lt $minBytes) {
            Write-Warn "  MSI is only $size bytes, which is implausibly small"
            if ($attempt -lt $attempts) { continue }
            throw "$DisplayName download produced a $size byte file after $attempts attempts."
        }

        $msiArgs = @('/i', "`"$installer`"", '/qn', '/norestart') + $ExtraArgs
        $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
        # 3010 = success, reboot required
        if ($proc.ExitCode -in @(0, 3010)) {
            Remove-Item $installer -Force -ErrorAction SilentlyContinue
            Write-Ok "$DisplayName installed"
            return
        }

        if ($proc.ExitCode -eq 1620 -and $attempt -lt $attempts) {
            Write-Warn "  msiexec 1620 (package could not be opened) on a $size byte file - retrying the download"
            continue
        }

        $hint = switch ($proc.ExitCode) {
            1620    { ' (ERROR_INSTALL_PACKAGE_INVALID - the file is corrupt or is not an MSI)' }
            1603    { ' (ERROR_INSTALL_FAILURE - a generic msiexec failure; check the MSI log)' }
            1618    { ' (ERROR_INSTALL_ALREADY_RUNNING - another install holds the installer mutex)' }
            default { '' }
        }
        throw "$DisplayName installation failed with exit code $($proc.ExitCode)$hint"
    }
}

# ----------------------------- steps -----------------------------

function Set-ProdNicRoutePriority {
    Write-Step 'Route priority (keep egress on the management NIC)'

    # CORRECTIVE, and it fires. This comment used to say "defensive, not
    # corrective", on the strength of one host on 2026-08-17 where Windows kept a
    # single default route via the management NIC and the function was a no-op.
    #
    # A reboot on 2026-08-31 settled it the other way. Same host, same NIC,
    # before and after:
    #
    #   before reboot   [skip] ifIndex <a> (<prod-nic-ip>) has no default route
    #   after  reboot   [ok]   removed default route on ifIndex <b> (<prod-nic-ip>)
    #
    # DHCP re-adds a 0.0.0.0/0 route on every prod NIC at every boot, and the
    # interface indices are renumbered too, so nothing that pins an index
    # survives either. Every VPC subnet offers its .1 as a gateway,
    # and the prod-mirroring subnets have no route to the internet by design - so
    # those routes are blackholes.
    #
    # UserData runs ONCE per instance. That is why Register-RoutePriorityTask
    # exists: a host that reboots later needs this to run again, or egress dies
    # and it presents as an SSM or image-pull fault rather than a routing one.
    #
    # It also serves as a diagnostic: it prints the live default routes and tests
    # egress.
    if (-not $Plan) {
        Write-Skip 'no flow plan - cannot identify prod NICs'
        return
    }

    $changed = 0
    foreach ($network in $Plan.networks) {
        $prefix = ($network.subnetCidr -split '/')[0] -replace '\.\d+$', '.'
        $addresses = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                     Where-Object { $_.IPAddress -like "$prefix*" }
        if (-not $addresses) {
            Write-Warn "no NIC found in $($network.subnetCidr) yet"
            continue
        }
        foreach ($address in $addresses) {
            $idx = $address.InterfaceIndex
            # A high interface metric persists across DHCP renewals and reboots, so
            # any default route re-added later still loses to the management NIC.
            Set-NetIPInterface -InterfaceIndex $idx -InterfaceMetric 9000 -ErrorAction SilentlyContinue
            $stale = Get-NetRoute -InterfaceIndex $idx -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue
            if ($stale) {
                $stale | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
                Write-Ok "removed default route on ifIndex $idx ($($address.IPAddress))"
                $changed++
            } else {
                Write-Skip "ifIndex $idx ($($address.IPAddress)) has no default route"
            }
        }
    }

    Write-Host '  default route(s) now:'
    Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric |
        ForEach-Object { Write-Host ("    ifIndex {0,-4} via {1,-15} metric {2}" -f $_.InterfaceIndex, $_.NextHop, $_.RouteMetric) }

    try {
        Invoke-WebRequest -Uri 'https://api.github.com' -UseBasicParsing -TimeoutSec 10 | Out-Null
        Write-Ok 'internet egress works'
    } catch {
        Write-Fail "no internet egress: $($_.Exception.Message)"
        Write-Warn 'The SSM Agent will not register and image pulls will fail until this is fixed.'
    }

    if ($changed -gt 0) {
        Write-Warn 'Removed blackhole default route(s). If the SSM Agent was already running it may take'
        Write-Warn 'a few minutes to register; restart it to speed that up:  Restart-Service AmazonSSMAgent'
    }
}

# Windows sets these when a servicing operation has staged changes that only
# take effect at boot. Chocolatey reads them, which is why its output said
# "a pending system reboot request has been detected" on a host where this
# script had just decided no reboot was necessary.
function Test-PendingReboot {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootInProgress'
    )
    foreach ($k in $keys) {
        if (Test-Path $k) { return $true }
    }
    # PendingFileRenameOperations usually does NOT exist, which is the whole
    # difficulty. Get-ItemProperty -Name <missing> returns $null even with
    # -ErrorAction SilentlyContinue, and this script runs under
    # Set-StrictMode -Version Latest, so dotting a property off that $null is the
    # same fault that killed the reboot path in Enable-ContainerFeatures. Worse,
    # it would fire on the HEALTHY host - the one with no reboot pending, which
    # is precisely the case that has to work.
    #
    # Read the key, then ask whether the property is there before touching it.
    $sm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
    $smKey = Get-ItemProperty -Path $sm -ErrorAction SilentlyContinue
    if ($smKey -and ($smKey.PSObject.Properties.Name -contains 'PendingFileRenameOperations')) {
        if ($smKey.PendingFileRenameOperations) { return $true }
    }
    return $false
}

# The DIRECT test, and the one that actually matters.
#
# The Containers feature installs the Host Compute Service (vmcompute). Until
# that service exists AND can run, the Docker engine cannot start a Windows
# container - and `Start-Service docker` fails with nothing useful in the
# message. Asking vmcompute is asking the real question; asking
# Install-WindowsFeature's RestartNeeded field is asking a proxy that lies.
function Test-ContainerPlatformLive {
    $vmcompute = Get-Service -Name vmcompute -ErrorAction SilentlyContinue
    if (-not $vmcompute) { return $false }
    if ($vmcompute.Status -eq 'Running') { return $true }
    try {
        Start-Service -Name vmcompute -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Register-RoutePriorityTask {
    Write-Step 'Persist route priority across reboots'

    # THE SCRIPT IS COPIED TO A STABLE PATH ON PURPOSE.
    #
    # This script normally runs from the extracted tarball directory, whose name
    # carries the bootstrap commit sha:
    #   C:\FlowTest\bootstrap\tooling\<owner>-<repo>-7043887\scripts\...
    # A scheduled task pointing there breaks the moment the host is bootstrapped
    # from a different commit, and it breaks SILENTLY - the task runs, fails to
    # find the file, and egress dies at the next reboot with nothing to link the
    # two events. Copying to a fixed path keeps one source of the route logic
    # (no duplicated function to drift) at an address that does not move.
    $stableDir  = 'C:\FlowTest\bootstrap'
    $stablePath = Join-Path $stableDir 'route-priority.ps1'
    $planPath   = if ($PlanFile) { (Resolve-Path $PlanFile -ErrorAction SilentlyContinue).Path } else { $null }
    if (-not $planPath) {
        Write-Skip 'no resolvable plan file - cannot register the boot task'
        return
    }

    $self = $PSCommandPath
    if (-not $self -or -not (Test-Path $self)) {
        Write-Skip 'cannot resolve this script path - skipping the boot task'
        return
    }

    try {
        if (-not (Test-Path $stableDir)) { $null = New-Item -ItemType Directory -Path $stableDir -Force }
        Copy-Item -Path $self -Destination $stablePath -Force

        $taskName = 'FlowTestRoutePriority'
        $argument = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -PlanFile "{1}" -RoutesOnly' -f $stablePath, $planPath
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
        # AT STARTUP IS NOT ENOUGH. Observed on a real host, 2026-09-01, across
        # three consecutive runs with NO reboot between them:
        #
        #   run 1   [ok]   removed default route on ifIndex 14/17
        #   run 2   [skip] ifIndex 14/17 has no default route
        #   run 3   [ok]   removed default route on ifIndex 14/17
        #
        # The blackhole routes came back from a DHCP LEASE RENEWAL, not a reboot.
        # A boot-only trigger would have already run and "succeeded" hours before
        # egress died, and the symptom would present as an SSM or image-pull
        # fault. So the task repeats for the life of the host.
        #
        # The work is idempotent and costs nothing when there is nothing to do -
        # it prints [skip] and exits - so a frequent interval is cheap insurance
        # against a failure mode that is otherwise silent and badly misleading.
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                        -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

        # Boot trigger, delayed: at AtStartup the NICs may not have finished DHCP,
        # and removing a route that has not been added yet accomplishes nothing.
        $bootTrigger = New-ScheduledTaskTrigger -AtStartup
        $bootTrigger.Delay = 'PT45S'

        # Repeating trigger for lease renewals. Registered as a SECOND trigger
        # rather than by setting Repetition on the boot trigger: a boot trigger's
        # repetition is not honoured consistently across Windows versions, and
        # this failing silently is exactly what it is meant to prevent.
        $repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
                            -RepetitionInterval (New-TimeSpan -Minutes 15)

        Register-ScheduledTask -TaskName $taskName -Action $action `
            -Trigger @($bootTrigger, $repeatTrigger) `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Write-Ok "scheduled task '$taskName' registered (at startup +45s, then every 15 min, as SYSTEM)"
        Write-Host "         runs: $stablePath -RoutesOnly"
    }
    catch {
        # Not fatal. The routes are correct RIGHT NOW because
        # Set-ProdNicRoutePriority already ran; this only protects a later reboot.
        Write-Warn "could not register the boot task: $($_.Exception.Message)"
        Write-Warn 'Egress is correct now but may not survive a reboot. Re-run this script after one.'
    }
}

function Enable-ContainerFeatures {
    Write-Step 'Windows container features'
    $rebootNeeded = $false

    $containers = Get-WindowsFeature -Name Containers -ErrorAction SilentlyContinue
    if ($containers -and -not $containers.Installed) {
        Write-Host '  installing Containers feature ...'
        $null = Install-WindowsFeature -Name Containers -ErrorAction Stop
        Write-Ok 'Containers feature installed'
        # DELIBERATELY NOT $result.RestartNeeded. See below.
    }
    elseif ($containers) {
        Write-Skip 'Containers feature already installed'
    }

    # DO NOT TRUST Install-WindowsFeature's RestartNeeded FIELD.
    #
    # This code used to read:
    #     if ($result.RestartNeeded -ne 'No') { $rebootNeeded = $true }
    # On Server 2022 that field comes back 'No' for the Containers feature even
    # though the container drivers are NOT live until the machine reboots. So
    # the script sailed past the reboot gate, installed MCR, and died on
    #     Start-Service : Failed to start service 'Docker Engine (docker)'
    # with no indication why - because from Docker's point of view there was
    # nothing to say: the platform underneath it simply was not there yet.
    # Chocolatey, running moments earlier in the same session, had already
    # detected the pending reboot and printed it four times.
    #
    # So test the two things that are actually true or false: is a servicing
    # reboot pending, and is the Host Compute Service able to run?
    if (Test-PendingReboot) {
        Write-Warn 'a servicing reboot is pending (registry), so container drivers are not live yet'
        $rebootNeeded = $true
    }
    elseif (-not (Test-ContainerPlatformLive)) {
        Write-Warn 'the Host Compute Service (vmcompute) is absent or will not start'
        $rebootNeeded = $true
    }
    else {
        Write-Ok 'container platform is live (vmcompute running, no reboot pending)'
    }

    # Hyper-V is only needed for Hyper-V isolated containers. Process isolation
    # is the default and is faster; enable Hyper-V only if you need isolation
    # or a base image whose kernel does not match the host.
    $hyperv = Get-WindowsFeature -Name Hyper-V -ErrorAction SilentlyContinue
    if ($hyperv -and -not $hyperv.Installed) {
        Write-Skip 'Hyper-V not installed (process isolation is used by default)'
    }

    if ($rebootNeeded) {
        # EXIT 3010, NOT 0. 3010 is the standard Windows "success, reboot
        # required" code, and the distinction is load-bearing.
        #
        # This used to exit 0. The bootstrap in UserData only checks
        # $LASTEXITCODE -eq 0, so it wrote the READY marker and reported
        # BOOTSTRAP COMPLETE for a host that had installed the Containers
        # feature and NOTHING ELSE - no container runtime, no docker.exe. The
        # readiness gates passed, the pipeline reported success, and the fault
        # only surfaced when someone tried to run a container by hand days
        # later.
        #
        # Exiting 3010 lets the caller tell "finished" from "needs a reboot to
        # continue", which is the difference between a usable host and one that
        # only looks usable.
        Write-Warn 'REBOOT REQUIRED before the container runtime can be installed.'
        if ($SkipReboot) {
            Write-Warn 'Re-run this script after rebooting to continue.'
            exit 3010
        }

        # Arrange to CONTINUE after the reboot. UserData runs once per instance
        # and never again, so without this the host comes back with the
        # Containers feature installed and nothing else - which is exactly what
        # happened: the runtime was never installed, yet the host was reported
        # ready and the gates passed on it.
        #
        # RunOnce fires once, as SYSTEM, at next boot. Nothing to clean up and no
        # way for it to repeat.
        # $PSCommandPath, NOT $MyInvocation.MyCommand.Path.
        #
        # This line used to read:
        #     $self = $MyInvocation.MyCommand.Path
        #     if (-not $self) { $self = $PSCommandPath }
        # Inside a FUNCTION, $MyInvocation.MyCommand is the FunctionInfo for
        # Enable-ContainerFeatures, and a FunctionInfo has no Path property. This
        # script runs under Set-StrictMode -Version Latest (line 69), where
        # reading a property that does not exist THROWS rather than returning
        # $null - so the fallback on the next line could never run. The guard was
        # unreachable by construction, and the reboot path died with
        #     The property 'Path' cannot be found on this object
        # after the platform gate had correctly decided a reboot was needed.
        #
        # $PSCommandPath is the script's own path regardless of scope, which is
        # what Register-RoutePriorityTask above already uses. The two should not
        # have differed; that inconsistency is what let this through.
        $self = $PSCommandPath
        if (-not $self -or -not (Test-Path $self)) {
            Write-Fail 'cannot resolve this script path, so the post-reboot resume cannot be registered.'
            Write-Warn 'Reboot manually, then re-run this script to continue.'
            exit 3010
        }
        $resumeArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$self`""
        if ($PlanFile)    { $resumeArgs += " -PlanFile `"$PlanFile`"" }
        if ($ReadyMarker) { $resumeArgs += " -ReadyMarker `"$ReadyMarker`"" }
        try {
            Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce' `
                -Name 'FlowTestBootstrapResume' -Value "powershell.exe $resumeArgs" -ErrorAction Stop
            Write-Ok 'resume registered; this script will continue automatically after the reboot'
        } catch {
            Write-Fail "could not register the resume: $($_.Exception.Message)"
            Write-Warn 'The host will reboot WITHOUT resuming. Re-run this script by hand afterwards.'
        }

        Write-Warn 'Rebooting in 15 seconds.'
        Start-Sleep -Seconds 15
        Restart-Computer -Force
        exit 3010
    }
}

function Install-Chocolatey {
    Write-Step 'Chocolatey'
    if (Test-CommandExists 'choco') {
        Write-Skip "already installed ($(choco --version))"
        return
    }
    # Optional: only used for convenience tooling, never for the container runtime.
    try {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:ChocolateyInstall = [Environment]::GetEnvironmentVariable('ChocolateyInstall', 'Machine')
        Write-Ok 'Chocolatey installed'
    } catch {
        Write-Warn "Chocolatey install failed: $($_.Exception.Message)"
        Write-Warn 'Continuing - it is only needed for optional tooling.'
    }
}

function Install-ChocoPackages {
    Write-Step 'Optional tooling (git, AWS CLI, JDK 17, 7zip)'

    # NONE of these are required to run containers, which is the whole point of
    # this host. They are conveniences:
    #   git    - not used at all; bootstrap fetches a tarball, and configs are
    #            materialised by the coordinator, not here
    #   aws    - only for S3 archive pulls (pipeline stages 5/10). AWS-provided
    #            Windows AMIs already ship the AWS CLI and AWS Tools for PowerShell
    #   java   - only if this host is ever used as a Jenkins agent
    #   7zip   - superseded by the built-in tar.exe
    # So a failure here must NEVER stop the run. Previously this threw on any
    # non-zero exit and piped choco's output to Out-Null, which turned a
    # cosmetic problem into a hard stop with no diagnostic. Both fixed.
    #
    # Chocolatey also sets ChocolateyInstall as a MACHINE variable, so a freshly
    # installed choco needs it copied into this process before it behaves.
    if (-not $env:ChocolateyInstall) {
        $env:ChocolateyInstall = [Environment]::GetEnvironmentVariable('ChocolateyInstall', 'Machine')
    }

    if (-not (Test-CommandExists 'choco')) {
        Write-Warn 'choco not on PATH - skipping optional tooling entirely'
        return
    }

    $packages = @(
        @{ Name = 'git';              Probe = 'git' },
        @{ Name = 'awscli';           Probe = 'aws' },
        @{ Name = $Config.JdkPackage; Probe = 'java' },
        @{ Name = '7zip';             Probe = $null }
    )
    foreach ($pkg in $packages) {
        if ($pkg.Probe -and (Test-CommandExists $pkg.Probe)) {
            Write-Skip "$($pkg.Name) already present"
            continue
        }
        Write-Host "  choco install $($pkg.Name) ..."
        # Show the output: exit codes alone are not diagnostic (choco returns 4
        # for several unrelated conditions).
        & choco install $pkg.Name -y --no-progress 2>&1 | ForEach-Object { Write-Host "    $_" }
        # 0 ok, 2 nothing to do, 350/1604/1641/3010 reboot-related
        if ($LASTEXITCODE -in @(0, 2, 350, 1604, 1641, 3010)) {
            Write-Ok "$($pkg.Name) installed (exit $LASTEXITCODE)"
        } else {
            Write-Warn "$($pkg.Name) did NOT install (exit $LASTEXITCODE) - continuing, it is optional"
        }
    }
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')

    # Temurin installs cleanly and still leaves java unusable.
    #
    # On a real host the package reported
    #     Deployed to 'C:\Program Files\Eclipse Adoptium\jdk-17.0.17.10-hotspot\'
    # and verification still said "java not available". The MSI does not extend
    # the machine PATH - the same class of problem already fixed for docker and
    # for git.
    #
    # Test-CommandRuns, NOT Test-CommandExists. The first attempt at this fix
    # used Test-CommandExists and did nothing at all, silently: Chocolatey's
    # openjdk17 package leaves a java.exe shim on the machine PATH, so the
    # command RESOLVED and the whole block was skipped, while `java -version`
    # still failed. Neither branch below printed anything, which is how a fix
    # that never ran looked identical to a fix that ran and worked.
    if (-not (Test-CommandRuns -Name 'java' -Arguments @('-version'))) {
        $jdkBin = Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory -ErrorAction SilentlyContinue |
                  Where-Object { Test-Path (Join-Path $_.FullName 'bin\java.exe') } |
                  Sort-Object Name -Descending |
                  Select-Object -First 1
        if ($jdkBin) {
            $binDir = Join-Path $jdkBin.FullName 'bin'
            $null = Add-MachinePathEntry -Directory $binDir -Label 'java'
            # PREPEND, not append. A broken Chocolatey shim earlier on the PATH
            # would otherwise keep winning over the real JDK we just added.
            $env:Path = "$binDir;$env:Path"
            if (Test-CommandRuns -Name 'java' -Arguments @('-version')) {
                Write-Ok 'java now works from the Adoptium JDK'
            } else {
                Write-Warn 'java still does not run after adding the JDK to PATH (optional, continuing)'
            }
        }
        else {
            Write-Skip 'no Eclipse Adoptium JDK found to add to PATH (java stays unavailable, it is optional)'
        }
    }
}

function Install-GitFallback {
    <#
        Install git WITHOUT Chocolatey.

        Chocolatey's git package failed on a real host with exit 4, and git is
        needed by later stages, so "optional and skipped" was the wrong outcome
        for something this easy to get another way.

        MinGit is the portable Git for Windows build: a ~37 MB zip with no
        installer, no admin prompt and no reboot. Extract it, put its cmd
        directory on the machine PATH, done. Fewer moving parts than an installer,
        and nothing to uninstall.
    #>
    if (Test-CommandExists 'git') {
        Write-Skip "git already present ($(git --version))"
        return
    }

    Write-Step 'git (Chocolatey fallback: MinGit)'
    $target = 'C:\FlowTest\tools\MinGit'
    $binDir = Join-Path $target 'cmd'

    if (Test-Path (Join-Path $binDir 'git.exe')) {
        Write-Skip "MinGit already extracted at $target"
        $null = Add-MachinePathEntry -Directory $binDir -Label 'git'
        return
    }

    try {
        # Resolve the current release rather than pinning a version that rots.
        # The API is unauthenticated and rate-limited per IP; a failure here is
        # not fatal, it just means no git.
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/git-for-windows/git/releases/latest' `
            -Headers @{ 'User-Agent' = 'flowtest-bootstrap' } -TimeoutSec 60

        $asset = $rel.assets |
            Where-Object { $_.name -like 'MinGit-*-64-bit.zip' -and $_.name -notlike '*busybox*' } |
            Select-Object -First 1
        if (-not $asset) { throw 'no MinGit 64-bit asset in the latest release' }

        $zip = Join-Path $env:TEMP $asset.name
        Write-Host "  downloading $($asset.name) ($([math]::Round($asset.size / 1MB)) MB) ..."
        Invoke-Download -Uri $asset.browser_download_url -OutFile $zip

        New-Item -ItemType Directory -Path $target -Force | Out-Null
        Expand-Archive -Path $zip -DestinationPath $target -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue

        if (-not (Test-Path (Join-Path $binDir 'git.exe'))) {
            throw "extracted, but no git.exe under $binDir"
        }
        $null = Add-MachinePathEntry -Directory $binDir -Label 'git'
        Write-Ok "git installed: $(& (Join-Path $binDir 'git.exe') --version)"
    }
    catch {
        # Still not fatal. git is needed by later stages, and they will say so
        # where they need it - which is better than failing a host that is
        # otherwise complete.
        Write-Warn "MinGit fallback failed: $($_.Exception.Message)"
        Write-Warn 'git is unavailable. Stages that need it will fail where they need it.'
    }
}

function Install-ContainerRuntime {
    Write-Step 'Mirantis Container Runtime'
    if (Test-CommandExists 'docker') {
        Write-Skip "docker already present ($(docker --version))"
        return
    }

    # Docker CE has no Windows Server build. MCR (built on CNCF Moby) is the
    # supported runtime for Windows Server containers.
    Write-Warn 'MCR is a licensed Mirantis product. Confirm entitlement before production use.'
    $installer = Join-Path $env:TEMP 'mcr-install.ps1'
    Write-Host "  downloading $($Config.McrInstallUrl) ..."
    Invoke-Download -Uri $Config.McrInstallUrl -OutFile $installer

    # A container platform that is not live is the single most likely reason for
    # this installer to fail, and it fails in a way that names Docker rather than
    # the platform. Say so BEFORE spending several minutes on a download that
    # cannot succeed.
    if (-not (Test-ContainerPlatformLive)) {
        Write-Fail 'the Host Compute Service (vmcompute) is not running.'
        Write-Warn 'The Containers feature needs a reboot to take effect. Reboot and re-run.'
        throw 'Container platform is not live; refusing to install the runtime.'
    }

    Write-Host '  running MCR installer (this can take several minutes) ...'
    # $ErrorActionPreference is 'Stop' for this script, and in PS 5.1 ANY stderr
    # output from a native command becomes a terminating ErrorRecord under that
    # setting. The MCR installer writes its own Start-Service failure to stderr,
    # so this line threw before the $LASTEXITCODE check below could run - and the
    # stack trace pointed here, at a `& powershell.exe` line, for a fault that
    # happened inside the installer. That is what made build 55 hard to read.
    #
    # Same hazard, same fix as Invoke-Docker in test-oe-console.ps1: drop to
    # 'Continue' for the call, capture, and decide from the exit code.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $mcrOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer 2>&1 | Out-String
        $mcrExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    if ($mcrOutput) { Write-Host ($mcrOutput.TrimEnd()) }

    if ($mcrExit -ne 0) {
        Write-Fail "MCR installer exited with $mcrExit"
        if ($mcrOutput -match 'Failed to start service') {
            Write-Warn 'It could not start the Docker engine service. That is almost always the'
            Write-Warn 'container platform not being live yet rather than a Docker fault.'
            $vm = Get-Service -Name vmcompute -ErrorAction SilentlyContinue
            Write-Warn "  vmcompute: $(if ($vm) { $vm.Status } else { 'NOT PRESENT' })"
            Write-Warn "  reboot pending: $(Test-PendingReboot)"
        }
        Write-Warn 'Alternative: containerd + nerdctl, or the Windows Admin Center Containers extension.'
        throw 'Container runtime installation failed.'
    }
    Remove-Item $installer -Force -ErrorAction SilentlyContinue

    # The MCR installer extends the MACHINE PATH, which does not affect this
    # already-running process. Without this refresh every later `docker` call
    # fails with CommandNotFoundException even though the install succeeded.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')

    # Persist docker.exe on the MACHINE PATH, not just for this session. The
    # installer usually does this, but it did not on the first host we built:
    # docker installed cleanly and every later call failed with
    #   docker : The term 'docker' is not recognized
    # A session-only fix hides that until the next boot or the next remote
    # command, so make it permanent whether or not the installer managed it.
    $dockerDir = 'C:\Program Files\Docker'
    if (-not (Test-Path (Join-Path $dockerDir 'docker.exe'))) {
        throw "MCR reported success but docker.exe was not found under $dockerDir"
    }
    $pathChanged = Add-MachinePathEntry -Directory $dockerDir -Label 'docker.exe'

    if (-not (Test-CommandExists 'docker')) {
        throw "docker.exe exists at $dockerDir but is still not resolvable on PATH"
    }
    if ($pathChanged) { Sync-ServiceEnvironment }

    # The installer usually registers the service; register it if it did not.
    if (-not (Get-Service docker -ErrorAction SilentlyContinue)) {
        Write-Host '  registering the docker service ...'
        & 'C:\Program Files\Docker\dockerd.exe' --register-service
    }
    Start-Service docker -ErrorAction SilentlyContinue
    Set-Service  docker -StartupType Automatic
    Write-Ok "runtime installed: $(docker --version)"
}

function Install-SqlClientTools {
    Write-Step 'SQL Server client tools (ODBC Driver 18 + sqlcmd) - optional'
    # Needed by the OE containers' DB access (pipeline stages 5/10), NOT by the
    # container runtime. Never fatal: a failure here must not block the runtime.
    try {

    # The OE reads its DB through an ODBC DSN (ServerConfiguration.ini DSN=,
    # FbDBConfig.xml <DSN>). The driver is needed in the container IMAGE; it is
    # installed on the host too so the pipeline can probe DB reachability.
    $driverInstalled = $false
    try {
        $driverInstalled = [bool](Get-OdbcDriver -Name 'ODBC Driver 18 for SQL Server' -ErrorAction SilentlyContinue)
    } catch { $driverInstalled = $false }

    if ($driverInstalled) {
        Write-Skip 'ODBC Driver 18 already installed'
    } else {
        Install-MsiFromUrl -Uri $Config.OdbcUrl -FileName 'msodbcsql18.msi' `
            -DisplayName 'ODBC Driver 18 for SQL Server' -ExtraArgs @('IACCEPTMSODBCSQLLICENSETERMS=YES')
    }

    if (Test-CommandExists 'sqlcmd') {
        Write-Skip 'sqlcmd already present'
    } else {
        # THE LICENSE PROPERTY NAME IS PACKAGE-SPECIFIC, and getting it wrong
        # produces msiexec 1603 - a completely generic "install failure" that
        # says nothing about a missing property.
        #
        # We passed IACCEPTMSSQLTOOLSLICENSETERMS, which belongs to the older
        # mssql-tools package and does not exist in this MSI at all. Reading the
        # MSI's own strings shows what it actually declares:
        #     IACCEPTMSSQLCMDLNUTILSLICENSETERMS
        # With the launch condition unsatisfied, the install aborts as 1603.
        #
        # Both are passed because an unknown property is harmless to msiexec (it
        # just becomes a property nobody reads), so this survives Microsoft
        # renaming the package again.
        Install-MsiFromUrl -Uri $Config.MsSqlToolsUrl -FileName 'mssql-tools18.msi' `
            -DisplayName 'mssql-tools18 (sqlcmd)' `
            -ExtraArgs @('IACCEPTMSSQLCMDLNUTILSLICENSETERMS=YES', 'IACCEPTMSSQLTOOLSLICENSETERMS=YES')
        # Same helper as docker. This used to call SetEnvironmentVariable(...,
        # 'Machine'), which rewrites PATH as REG_SZ and stops %SystemRoot% style
        # entries expanding, and it matched on substring so a similarly named
        # folder would have counted as already present.
        $toolsBin = 'C:\Program Files\Microsoft SQL Server\Client SDK\ODBC\180\Tools\Binn'
        $null = Add-MachinePathEntry -Directory $toolsBin -Label 'sqlcmd'
    }
    } catch {
        Write-Warn "SQL client tools not installed: $($_.Exception.Message)"
        Write-Warn 'Continuing - only the DB stages need these.'
    }
}

function Install-HnsModule {
    Write-Step 'HNS PowerShell module'
    if (Get-Module -ListAvailable -Name HostNetworkingService -ErrorAction SilentlyContinue) {
        Write-Skip 'HostNetworkingService module already available'
        return
    }
    try {
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -Force -Scope AllUsers | Out-Null
        }
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
        Install-Module -Name HostNetworkingService -Force -Scope AllUsers -AllowClobber
        Write-Ok 'HostNetworkingService module installed'
    } catch {
        Write-Warn "could not install HNS module: $($_.Exception.Message)"
        Write-Warn 'Not fatal - docker network commands still work. The module only helps with HNS troubleshooting.'
    }
}

function Get-AdapterForSubnet {
    param([string]$Cidr)

    # Match a physical adapter carrying an address inside $Cidr.
    $network = $Cidr.Split('/')[0]
    $prefix  = [int]$Cidr.Split('/')[1]
    $octets  = $network.Split('.')
    $wanted  = ($octets[0..2] -join '.')   # /24 assumption, matching the design

    if ($prefix -ne 24) {
        Write-Warn "adapter matching assumes /24; got /$prefix for $Cidr"
    }

    $candidates = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -like "$wanted.*" -and $_.InterfaceAlias -notlike 'vEthernet*' -and $_.InterfaceAlias -ne 'Loopback Pseudo-Interface 1' }

    if (-not $candidates) { return $null }
    return ($candidates | Select-Object -First 1)
}

function New-L2BridgeNetwork {
    param(
        [string]$Name,
        [string]$Subnet,
        [string]$Gateway,
        [string[]]$PlannedIPs
    )

    $existing = & docker network ls --filter "name=^$Name$" --format '{{.Name}}' 2>$null
    if ($existing -eq $Name) {
        Write-Skip "network '$Name' already exists"
        return
    }

    $adapter = Get-AdapterForSubnet -Cidr $Subnet
    if (-not $adapter) {
        Write-Warn "no adapter found carrying an address in $Subnet - skipping '$Name'"
        Write-Warn 'Check that the secondary ENI is attached AND the OS has an IP on it:'
        Write-Warn '  Get-NetIPAddress -AddressFamily IPv4 | Format-Table IPAddress,InterfaceAlias'
        return
    }
    Write-Host "  $Subnet is on adapter '$($adapter.InterfaceAlias)' ($($adapter.IPAddress))"

    # l2bridge: containers get IPs from the host subnet, MACs rewritten to the
    # host NIC's MAC - required on EC2, which filters foreign MACs.
    # NOTE: do not name this $args - that is a PowerShell automatic variable.
    $dockerArgs = @(
        'network', 'create',
        '--driver', 'l2bridge',
        '--subnet', $Subnet,
        '--gateway', $Gateway,
        '-o', "com.docker.network.windowsshim.interface=$($adapter.InterfaceAlias)",
        '-o', "com.docker.network.windowsshim.networkname=$Name",
        $Name
    )
    Write-Host "  docker $($dockerArgs -join ' ')"
    & docker @dockerArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "failed to create network '$Name'"
        # l2bridge on EC2 was proven on hardware 2026-08-17, so a failure here is
        # a fault with THIS host, not an unanswered design question. The usual
        # causes, in order:
        Write-Warn 'l2bridge works on EC2 (proven 2026-08-17), so this is a fault with this host. Check:'
        Write-Warn '  - the adapter above is the right prod NIC and is UP'
        Write-Warn '  - the host address on it does not collide with a planned container address'
        Write-Warn '  - the docker service is running and in Windows container mode'
        return
    }
    Write-Ok "network '$Name' created ($Subnet via $($adapter.InterfaceAlias))"
    Write-Host "         planned container IPs: $($PlannedIPs -join ', ')"
}

function Initialize-DockerNetworks {
    Write-Step 'Docker networks (l2bridge, prod-exact IPs)'
    if ($SkipNetworks) {
        Write-Skip 'skipped by -SkipNetworks'
        return
    }
    if (-not $Plan) {
        Write-Skip 'no flow plan - nothing to create'
        return
    }
    foreach ($network in $Plan.networks) {
        New-L2BridgeNetwork -Name $network.dockerNetwork -Subnet $network.subnetCidr `
            -Gateway $network.gateway -PlannedIPs $network.containerIps
    }
}

function Get-BaseImages {
    Write-Step "Base image: $($Config.BaseImage)"
    $present = & docker images --format '{{.Repository}}:{{.Tag}}' 2>$null | Where-Object { $_ -eq $Config.BaseImage }
    if ($present) {
        Write-Skip 'base image already pulled'
        return
    }
    Write-Host '  pulling (multi-GB, expect several minutes) ...'
    & docker pull $Config.BaseImage
    if ($LASTEXITCODE -ne 0) { throw "docker pull $($Config.BaseImage) failed" }
    Write-Ok 'base image pulled'
}

function Initialize-Directories {
    Write-Step 'Working directories'
    $dirs = @(
        $Config.WorkRoot,
        (Join-Path $Config.WorkRoot 'configs'),
        (Join-Path $Config.WorkRoot 'logs'),
        (Join-Path $Config.WorkRoot 'messages'),
        (Join-Path $Config.WorkRoot 'artifacts')
    )
    foreach ($dir in $dirs) {
        if (Test-Path $dir) { Write-Skip $dir }
        else { New-Item -ItemType Directory -Path $dir -Force | Out-Null; Write-Ok $dir }
    }
}

function Test-Prerequisites {
    Write-Step 'Verification'
    $failures = @()

    # Only the container runtime is REQUIRED. Everything else is convenience
    # tooling for later pipeline stages and must not fail this host.
    # Name + Arguments, resolved through Get-CommandVersion, NOT ad-hoc
    # scriptblocks. The scriptblocks ran under $ErrorActionPreference='Stop',
    # where PS 5.1 turns native stderr into a terminating error - and
    # `java -version` writes its banner to stderr. So this loop could report a
    # perfectly working tool as "not available", which is exactly what it did:
    # the install path (asking a different way) saw java working and correctly
    # skipped its PATH fix, while this loop warned java was missing. One of the
    # two was lying and there was no way to tell which from the log.
    $checks = @(
        @{ Label = 'docker';  Required = $true;  Name = 'docker'; Arguments = @('--version') },
        @{ Label = 'git';     Required = $false; Name = 'git';    Arguments = @('--version') },
        @{ Label = 'aws';     Required = $false; Name = 'aws';    Arguments = @('--version') },
        @{ Label = 'java';    Required = $false; Name = 'java';   Arguments = @('-version') },
        @{ Label = 'sqlcmd';  Required = $false; Name = 'sqlcmd'; Arguments = @('-?') }
    )
    # Verify the PERSISTED PATH, not just this session's. $env:Path was patched
    # in-process during the install, so a check that only looks there would pass
    # on a host where the next boot - or the next ssm send-command - cannot find
    # docker at all. That is precisely the failure this verification exists for.
    $persistedPath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $normalize = { param($p) $p.Trim().TrimEnd('\').ToLowerInvariant() }
    $persistedDirs = @($persistedPath -split ';' | Where-Object { $_.Trim() -ne '' } | ForEach-Object { & $normalize $_ })
    if ($persistedDirs -contains (& $normalize 'C:\Program Files\Docker')) {
        Write-Ok 'docker.exe is on the persisted machine PATH (survives reboot and remote commands)'
    } else {
        Write-Fail 'docker.exe is NOT on the persisted machine PATH (REQUIRED)'
        Write-Warn 'It may work in this session and then fail after a reboot or via ssm send-command.'
        $failures += 'docker-on-machine-path'
    }

    foreach ($check in $checks) {
        $result = Get-CommandVersion -Name $check.Name -Arguments $check.Arguments
        if ($result.Ok) {
            Write-Ok "$($check.Label): $($result.Text)"
        }
        elseif ($check.Required) {
            Write-Fail "$($check.Label) not working (REQUIRED): $($result.Text)"
            $failures += $check.Label
        }
        else {
            # Say WHY, not just that it is missing. "java not available" sent us
            # looking for an install problem when the tool was on PATH.
            Write-Warn "$($check.Label) not available (optional): $($result.Text)"
        }
    }

    try {
        $svc = Get-Service docker -ErrorAction Stop
        if ($svc.Status -eq 'Running') { Write-Ok 'docker service running' }
        else { Write-Fail "docker service is $($svc.Status)"; $failures += 'docker service' }
    } catch { Write-Fail 'docker service not found'; $failures += 'docker service' }

    Write-Host "`n  Docker networks:"
    & docker network ls 2>$null | ForEach-Object { Write-Host "    $_" }

    Write-Host "`n  IPv4 addresses on this host:"
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -ne '127.0.0.1' } |
        Sort-Object InterfaceAlias |
        ForEach-Object { Write-Host ("    {0,-18} {1}" -f $_.IPAddress, $_.InterfaceAlias) }

    if ($Plan -and $Plan.peers -and $Plan.peers.Count -gt 0) {
        Write-Host "`n  Cross-host reachability (peers from the flow plan):"
        foreach ($target in $Plan.peers) {
            if (Test-Connection -ComputerName $target -Count 1 -Quiet -ErrorAction SilentlyContinue) {
                Write-Ok "$target reachable"
            } else {
                Write-Warn "$target unreachable (expected until the other host has bootstrapped)"
            }
        }
    }

    if ($failures.Count -gt 0) {
        Write-Host ''
        Write-Fail "incomplete: $($failures -join ', ')"
        exit 1
    }
    Write-Host ''
    Write-Ok 'All Windows host prerequisites satisfied.'

    # Write the readiness marker HERE, at the only point where the host is
    # genuinely usable.
    #
    # It used to be written solely by the bootstrap, on exit code 0 - and the
    # reboot path exited 0, so a host with the Containers feature and no
    # container runtime was marked ready. Owning the marker here means it can
    # only appear after verification has actually passed, including on a run
    # that resumed after a reboot.
    if ($ReadyMarker) {
        try {
            $dir = Split-Path -Parent $ReadyMarker
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            Set-Content -Path $ReadyMarker -Value (Get-Date -Format o) -Encoding ASCII
            Write-Ok "readiness marker written: $ReadyMarker"
        } catch {
            Write-Fail "could not write the readiness marker: $($_.Exception.Message)"
            exit 1
        }
    }
}

# ----------------------------- main -----------------------------

try {
    Write-Host ''
    Write-Host '  VCVW Flow - Windows container host prerequisites' -ForegroundColor White
    Write-Host "  script version $ScriptVersion" -ForegroundColor DarkGray
    Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray

    Assert-Administrator

    # -RoutesOnly is the boot-task entry point. It must do the minimum and get
    # out: at startup this runs before anything else needs the host, and a full
    # prerequisite pass at every boot would be both slow and surprising.
    if ($RoutesOnly) {
        Import-FlowPlan
        Set-ProdNicRoutePriority
        Write-Ok 'route priority reapplied after boot'
        exit 0
    }

    Assert-SupportedOs
    Import-FlowPlan
    Set-ProdNicRoutePriority   # must precede anything that needs the network
    Register-RoutePriorityTask # ...and must keep being applied after a reboot

    Enable-ContainerFeatures
    Install-Chocolatey
    Install-ChocoPackages
    # Runs only if git is still missing. Chocolatey's git package has failed on a
    # real host (exit 4) and the packages are installed non-fatally, so without
    # this a host silently ends up without git.
    Install-GitFallback
    Install-ContainerRuntime
    Install-SqlClientTools
    Install-HnsModule
    Initialize-Directories
    Get-BaseImages
    Initialize-DockerNetworks
    Test-Prerequisites

    # Print next steps using values from the plan, so this script carries no
    # environment-specific addresses of its own.
    $img = $Config.BaseImage
    $exampleNet = if ($Plan -and $Plan.networks) { $Plan.networks[0].dockerNetwork } else { '<network>' }
    $exampleIp  = if ($Plan -and $Plan.networks -and $Plan.networks[0].containerIps) { $Plan.networks[0].containerIps[0] } else { '<ip>' }
    $sharedGroup = if ($Plan) { $Plan.groups | Where-Object { $_.sharedNamespace } | Select-Object -First 1 } else { $null }

    Write-Host "`nNext steps" -ForegroundColor Gray
    Write-Host @"
  1. Build the engine images for the tags in the plan:
       .\build-images.ps1 -GitHubTokenSecretId flowtest/github-pat
     Tags already in ECR are skipped, so this is a no-op for an unchanged flow.

  2. The console question is ANSWERED for the runtime (probed 2026-08-31): a real
     console handler installed and NO event arrived in 120s across four container
     shapes, so the runtime sends nothing unprompted. Still worth confirming for
     the engine itself once an OE image exists:
       .\test-oe-console.ps1 -Mode image -Image <ref> -ConfigDir <dir>
     Use plain detached - no -i, no -t.

"@ -ForegroundColor Gray

    Write-Host @'
  3. Stage the configs and start the containers with run-engine.ps1, which
     copies config INTO the engine directory - the engine has no config-path
     argument, so a mount alongside it will not be found.

'@ -ForegroundColor Gray
}
catch {
    Write-Host ''
    Write-Fail $_.Exception.Message
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    exit 1
}
