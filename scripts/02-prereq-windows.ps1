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
    [switch]$SkipNetworks
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ----------------------------- configuration -----------------------------

# Host-level constants only. Everything flow-specific comes from $PlanFile.
$script:Config = @{
    BaseImage      = 'mcr.microsoft.com/windows/servercore:ltsc2022'
    JdkPackage     = 'openjdk17'
    McrInstallUrl  = 'https://get.mirantis.com/install.ps1'
    OdbcUrl        = 'https://go.microsoft.com/fwlink/?linkid=2280794'   # msodbcsql18 x64
    MsSqlToolsUrl  = 'https://go.microsoft.com/fwlink/?linkid=2280795'   # mssql-tools18 x64
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
    Write-Host "  downloading $DisplayName ..."
    Invoke-Download -Uri $Uri -OutFile $installer

    $msiArgs = @('/i', "`"$installer`"", '/qn', '/norestart') + $ExtraArgs
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
    # 3010 = success, reboot required
    if ($proc.ExitCode -notin @(0, 3010)) {
        throw "$DisplayName installation failed with exit code $($proc.ExitCode)"
    }
    Remove-Item $installer -Force -ErrorAction SilentlyContinue
    Write-Ok "$DisplayName installed"
}

# ----------------------------- steps -----------------------------

function Set-ProdNicRoutePriority {
    Write-Step 'Route priority (keep egress on the management NIC)'

    # DEFENSIVE, not corrective. Measured on a real host (2026-08-17): Windows
    # kept one default route via the management NIC and egress worked, so a
    # blackhole route was NOT what broke bootstrap or SSM registration - that was
    # transient network readiness at boot.
    #
    # Retained as cheap insurance, because the failure mode would be silent and
    # confusing if it ever occurred: every VPC subnet offers its .1 as a gateway
    # over DHCP, and the prod-mirroring subnets have no 0.0.0.0/0 route by design.
    # This function is a no-op on a correctly-routed host. It also serves as a
    # diagnostic: it prints the live default routes and tests egress.
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

function Enable-ContainerFeatures {
    Write-Step 'Windows container features'
    $rebootNeeded = $false

    $containers = Get-WindowsFeature -Name Containers -ErrorAction SilentlyContinue
    if ($containers -and -not $containers.Installed) {
        Write-Host '  installing Containers feature ...'
        $result = Install-WindowsFeature -Name Containers -ErrorAction Stop
        Write-Ok 'Containers feature installed'
        if ($result.RestartNeeded -ne 'No') { $rebootNeeded = $true }
    }
    elseif ($containers) {
        Write-Skip 'Containers feature already installed'
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
        $self = $MyInvocation.MyCommand.Path
        if (-not $self) { $self = $PSCommandPath }
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

    Write-Host '  running MCR installer (this can take several minutes) ...'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "MCR installer exited with $LASTEXITCODE"
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
        Install-MsiFromUrl -Uri $Config.MsSqlToolsUrl -FileName 'mssql-tools18.msi' `
            -DisplayName 'mssql-tools18 (sqlcmd)' -ExtraArgs @('IACCEPTMSSQLTOOLSLICENSETERMS=YES')
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
    $checks = @(
        @{ Label = 'docker';  Required = $true;  Script = { docker --version } },
        @{ Label = 'git';     Required = $false; Script = { git --version } },
        @{ Label = 'aws';     Required = $false; Script = { aws --version } },
        @{ Label = 'java';    Required = $false; Script = { java -version 2>&1 | Select-Object -First 1 } },
        @{ Label = 'sqlcmd';  Required = $false; Script = { sqlcmd -? 2>&1 | Select-Object -First 1 } }
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
        try {
            $out = & $check.Script 2>&1 | Out-String
            Write-Ok "$($check.Label): $($out.Trim() -split "`n" | Select-Object -First 1)"
        } catch {
            if ($check.Required) {
                Write-Fail "$($check.Label) not working (REQUIRED)"
                $failures += $check.Label
            } else {
                Write-Warn "$($check.Label) not available (optional)"
            }
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
    Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray

    Assert-Administrator
    Assert-SupportedOs
    Import-FlowPlan
    Set-ProdNicRoutePriority   # must precede anything that needs the network

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

  2. Before any flow uses an oe or oe-risk image, run the console probe once:
       .\test-oe-console.ps1
     The order execution server has been seen dying ~45s after launch when it
     does not own its console. Inside a flow that looks like a network fault.

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
