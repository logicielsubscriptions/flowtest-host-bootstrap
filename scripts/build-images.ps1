<#
.SYNOPSIS
    Build the WINDOWS engine images for a flow and push them to ECR.

.DESCRIPTION
    Reads the generated host plan, works out which (imageFamily, engineRepo, tag)
    combinations the flow needs, downloads each tag archive from the private
    deployment repo, and builds one image per combination.

    WHY THIS RUNS HERE AND NOT ON THE JENKINS AGENT
    Windows container images can only be built on a Windows host whose kernel
    matches the base image. servercore:ltsc2022 needs host build 20348. The Linux
    Jenkins agent cannot build these at all. This script is meant to run ON the
    flow-test Windows host, which already has Docker, the base image and an
    instance role from 02-prereq-windows.ps1.

    ECR, NOT GHCR
    The hosts pull with their instance role, which already carries
    AmazonEC2ContainerRegistryReadOnly. No registry secret is distributed to any
    host, and nothing needs rotating. ECR login below uses the instance role too.

    THE GITHUB TOKEN
    Only this script needs one, and only to read the private deployment repos.
    Preferred source is Secrets Manager via the instance role, so the value is
    never typed or stored on disk. It is passed to curl through a config file so
    it never appears in a command line or process list, and it is never passed as
    a docker build arg - build args are recorded in image history.

.EXAMPLE
    .\build-images.ps1 -GitHubTokenSecretId flowtest/github-pat

.EXAMPLE
    .\build-images.ps1 -PlanFile C:\flowtest\flow-plan-windows.json -DryRun
#>

[CmdletBinding()]
param(
    [string] $PlanFile,
    [string] $Region = 'us-east-1',
    [string] $EcrNamespace = 'flowtest',
    # NO DEFAULT. The owning org is read from the flow plan's engineRepoOwner.
    #
    # It used to be hardcoded here, which made this file unpublishable: the
    # content guard in sync-bootstrap-repo.sh rejects the org name, and rightly
    # so - this script has to live in a PUBLIC repo for the hosts to fetch it.
    # The plan is the right carrier because it is a per-build artifact that never
    # leaves the account, which is the same reason the addresses live there.
    # Pass this only to override the plan.
    [string] $GitHubOwner,
    [string] $GitHubTokenSecretId,
    [switch] $Force,
    [switch] $SkipPush,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

# Printed on every run. See the note in scripts/02-prereq-windows.ps1: without a
# version in the output a stale fetch is invisible, and a retest can silently
# re-run old code while looking like a fresh result.
$ScriptVersion = '2026-09-01.2-buildimages-routerepeat'
Write-Host "  script version $ScriptVersion" -ForegroundColor DarkGray
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# output helpers. Everything diagnostic goes to the host; only the summary is
# meant to be read by a human at the end.
# ---------------------------------------------------------------------------
function Write-Step { param([string] $Message) Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "  [ok]   $Message" -ForegroundColor Green }
function Write-Skip { param([string] $Message) Write-Host "  [skip] $Message" -ForegroundColor DarkGray }
function Write-Warn { param([string] $Message) Write-Host "  [warn] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string] $Message) Write-Host "  [FAIL] $Message" -ForegroundColor Red }

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# imageFamily -> Dockerfile directory. oe and oe-risk share one Dockerfile: same
# binary, same base, same ODBC dependency, only the source repo differs.
$DockerfileFor = @{
    'oe'        = 'windows-oe'
    'oe-risk'   = 'windows-oe'
    'fixengine' = 'windows-fixengine'
}

# ---------------------------------------------------------------------------
function Test-Prerequisites {
    Write-Step 'Preflight'

    # Do not depend on PATH. This script is usually invoked through
    # ssm send-command, whose shell inherits the SSM Agent's environment as it
    # was when the agent started - so a PATH entry added after that is invisible
    # here even though an interactive session sees it fine. Fall back to the
    # known install location rather than failing on a machine where docker is
    # plainly installed.
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        $dockerDir = 'C:\Program Files\Docker'
        if (Test-Path (Join-Path $dockerDir 'docker.exe')) {
            $env:Path = "$env:Path;$dockerDir"
            Write-Warn "docker was not on PATH; using $dockerDir for this session"
            Write-Warn 'Re-run 02-prereq-windows.ps1 to persist it, or reboot so services pick it up.'
        } else {
            throw 'docker not found on PATH or at C:\Program Files\Docker. Run 02-prereq-windows.ps1 first.'
        }
    }
    Write-Ok "docker: $((docker --version) 2>&1)"

    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        throw 'aws CLI not found on PATH. 02-prereq-windows.ps1 installs it.'
    }
    Write-Ok 'aws CLI present'

    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw 'curl.exe not found. It ships with Server 2022; check the PATH.'
    }

    # Windows container images must match the host kernel. This is the single
    # most common reason a Windows image build or run fails, so fail loudly.
    $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
    if ($build -eq 20348) {
        Write-Ok "host build $build - matches servercore:ltsc2022"
    }
    else {
        Write-Warn "host build $build is NOT 20348 (Server 2022)."
        Write-Warn 'ltsc2022 images will not run here. Pass -BaseImage via the Dockerfile ARG for the matching tag'
        Write-Warn '(build 17763 -> ltsc2019). Continuing, but the built image will not match this host.'
    }

    # 2>&1 on a native command under EAP=Stop turns stderr into a terminating
    # error. Ask for the value without merging the streams.
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $info = & docker info --format '{{.OSType}}' 2>$null
    $ErrorActionPreference = $prevEap
    if ("$info".Trim() -ne 'windows') {
        throw "the Docker daemon is in '$info' mode, not windows. Switch to Windows containers before building."
    }
    Write-Ok 'daemon is in Windows container mode'
}

# ---------------------------------------------------------------------------
function Resolve-PlanFile {
    if ($PlanFile) {
        if (-not (Test-Path $PlanFile)) { throw "plan file not found: $PlanFile" }
        return (Resolve-Path $PlanFile).Path
    }
    # THE BOOTSTRAP LOCATION COMES FIRST, and it was missing entirely.
    #
    # UserData writes the plan to C:\FlowTest\bootstrap\flow-plan-windows.json.
    # The list below looked in C:\flowtest\ - a different directory, not just a
    # different case - so on a real flow-test host this script would have failed
    # with "no flow-plan-windows.json found" even though the plan was sitting
    # right there. It went unnoticed because the script has never run on a host:
    # it could not be published until the org name moved into the plan.
    $candidates = @(
        'C:\FlowTest\bootstrap\flow-plan-windows.json',
        (Join-Path $ScriptRoot '..\flow-plan-windows.json'),
        (Join-Path $ScriptRoot '..\build\flow-plan-windows.json'),
        (Join-Path $ScriptRoot 'flow-plan-windows.json'),
        'C:\flowtest\flow-plan-windows.json'
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { return (Resolve-Path $c).Path }
    }
    throw ('no flow-plan-windows.json found. Pass -PlanFile explicitly. Looked in: ' + ($candidates -join '; '))
}

# ---------------------------------------------------------------------------
function Get-BuildMatrix {
    param([string] $Path)

    Write-Step 'Build matrix from the flow plan'
    $plan = Get-Content -Raw -Path $Path | ConvertFrom-Json
    Write-Ok "flow $($plan.flow), host role $($plan.hostRole), market date $($plan.marketDate)"

    # Resolve the engine repo owner from the plan unless overridden on the command
    # line. Fail LOUDLY rather than guessing: a wrong owner produces a 404 from
    # the GitHub API, which reads as "tag does not exist" and sends you looking
    # at the deployment repo instead of at the plan.
    if (-not $script:GitHubOwner) {
        if ($plan.PSObject.Properties.Name -contains 'engineRepoOwner' -and $plan.engineRepoOwner) {
            $script:GitHubOwner = $plan.engineRepoOwner
            Write-Ok "engine repo owner from plan: $($script:GitHubOwner)"
        }
        else {
            throw ('the plan has no engineRepoOwner, so the deployment repo owner is unknown. ' +
                   'Regenerate the plan with a current generator, or pass -GitHubOwner explicitly.')
        }
    }
    else {
        Write-Skip "engine repo owner overridden on the command line: $($script:GitHubOwner)"
    }

    $seen = @{}
    $matrix = New-Object System.Collections.ArrayList

    foreach ($group in $plan.groups) {
        foreach ($svc in $group.services) {
            $family = $svc.imageFamily

            if ($family -eq 'fixhub-linux') {
                Write-Skip "$($svc.serviceName): fixhub-linux is a Linux image - build it with build-images.sh"
                continue
            }
            if (-not $DockerfileFor.ContainsKey($family)) {
                throw "no Dockerfile mapped for imageFamily '$family' (component $($svc.serviceName)). Add it to `$DockerfileFor and create images\<dir>\Dockerfile."
            }

            # One image per (family, repo, tag). Two components sharing all three
            # share the image - which is the point of not baking config.
            $key = "$family|$($svc.engineRepo)|$($svc.tag)"
            if ($seen.ContainsKey($key)) {
                Write-Skip "$($svc.serviceName): reuses $family`:$($svc.tag) already in the matrix"
                continue
            }
            $seen[$key] = $true

            $null = $matrix.Add([pscustomobject]@{
                ImageFamily = $family
                EngineRepo  = $svc.engineRepo
                Tag         = $svc.tag
                Binary      = $svc.binary
                Context     = Join-Path $ScriptRoot $DockerfileFor[$family]
                Components  = @($svc.serviceName)
            })
            Write-Ok "$family`:$($svc.tag)  <- $($svc.engineRepo)@$($svc.tag)  ($($svc.binary))"
        }
    }

    if ($matrix.Count -eq 0) { throw 'nothing to build: the plan has no Windows components' }
    return $matrix
}

# ---------------------------------------------------------------------------
function Get-GitHubToken {
    Write-Step 'GitHub token for the private deployment repos'

    if ($GitHubTokenSecretId) {
        # Preferred: the instance role reads it. Nothing is typed, nothing is
        # stored on the host, and rotation happens in one place.
        $value = (aws secretsmanager get-secret-value --secret-id $GitHubTokenSecretId --region $Region --query SecretString --output text) 2>&1
        if ($LASTEXITCODE -ne 0) { throw "could not read secret '$GitHubTokenSecretId': $value" }
        # Accept either a bare token or {"token":"..."}
        $text = "$value".Trim()
        if ($text.StartsWith('{')) {
            $obj = $text | ConvertFrom-Json
            $text = if ($obj.token) { $obj.token } elseif ($obj.GITHUB_TOKEN) { $obj.GITHUB_TOKEN } else { throw "secret '$GitHubTokenSecretId' is JSON but has no 'token' key" }
        }
        Write-Ok "read from Secrets Manager ($GitHubTokenSecretId)"
        return $text
    }

    if ($env:GITHUB_TOKEN) {
        Write-Warn 'using $env:GITHUB_TOKEN. Prefer -GitHubTokenSecretId so the value is never on the host.'
        return $env:GITHUB_TOKEN
    }

    throw @'
no GitHub token available. The deployment repos are private, so the tag archive
cannot be downloaded without one. Either:
  -GitHubTokenSecretId flowtest/github-pat     (preferred - read via instance role)
  $env:GITHUB_TOKEN = '...'                    (session only)
The token needs read access to the deployment repos only (contents: read).
'@
}

# ---------------------------------------------------------------------------
function Get-EcrRegistry {
    Write-Step 'ECR registry'
    $account = (aws sts get-caller-identity --query Account --output text) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "aws sts get-caller-identity failed: $account" }
    $registry = "$("$account".Trim()).dkr.ecr.$Region.amazonaws.com"
    Write-Ok $registry
    return $registry
}

function Confirm-EcrRepository {
    param([string] $RepoName)

    $null = (aws ecr describe-repositories --repository-names $RepoName --region $Region) 2>&1
    if ($LASTEXITCODE -eq 0) { return }

    if ($DryRun) { Write-Skip "would create ECR repository $RepoName"; return }

    $out = (aws ecr create-repository --repository-name $RepoName --region $Region `
                --image-scanning-configuration scanOnPush=true `
                --image-tag-mutability IMMUTABLE) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "could not create ECR repository ${RepoName}: $out" }
    # IMMUTABLE on purpose: an engine tag is a released build. If a tag could be
    # overwritten, two runs could use different code under one name and the
    # difference would surface as a replay mismatch.
    Write-Ok "created ECR repository $RepoName (immutable tags, scan on push)"
}

function Test-ImageExists {
    param([string] $RepoName, [string] $Tag)
    $null = (aws ecr describe-images --repository-name $RepoName --image-ids "imageTag=$Tag" --region $Region) 2>&1
    return ($LASTEXITCODE -eq 0)
}

# ---------------------------------------------------------------------------
function Get-EngineSource {
    param(
        [string] $Repo,
        [string] $Tag,
        [string] $Token,
        [string] $ContextDir
    )

    $engineDir = Join-Path $ContextDir 'engine'
    if (Test-Path $engineDir) { Remove-Item -Recurse -Force $engineDir }

    $work = Join-Path $env:TEMP ("flowtest-src-" + [guid]::NewGuid().ToString('N'))
    $null  = New-Item -ItemType Directory -Path $work -Force
    $zip   = Join-Path $work 'src.zip'

    # The token goes in a curl config file, not on the command line, so it never
    # lands in a process listing or a transcript. Deleted immediately after.
    $cfg = Join-Path $work 'curl.cfg'
    $url = "https://api.github.com/repos/$GitHubOwner/$Repo/zipball/$Tag"
    $lines = @(
        'silent',
        'show-error',
        'location',
        'fail',
        "url = `"$url`"",
        "header = `"Authorization: Bearer $Token`"",
        'header = "Accept: application/vnd.github+json"',
        'header = "X-GitHub-Api-Version: 2022-11-28"',
        "output = `"$zip`""
    )
    Set-Content -Path $cfg -Value $lines -Encoding ASCII

    try {
        $out = (curl.exe --config $cfg) 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "download failed for $Repo@${Tag} (curl exit $LASTEXITCODE): $out"
        }
    }
    finally {
        Remove-Item -Force $cfg -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $zip)) { throw "no archive downloaded for $Repo@$Tag" }
    $sizeMb = [math]::Round((Get-Item $zip).Length / 1MB, 1)

    $expand = Join-Path $work 'x'
    Expand-Archive -Path $zip -DestinationPath $expand -Force

    # A GitHub tag archive wraps everything in one folder named
    # <owner>-<repo>-<sha>. Flatten it, and keep the sha for provenance.
    $top = Get-ChildItem -Path $expand -Directory
    if ($top.Count -ne 1) {
        throw "expected exactly one top-level folder in the archive for $Repo@$Tag, found $($top.Count)"
    }
    $sha = ($top[0].Name -split '-')[-1]

    Move-Item -Path $top[0].FullName -Destination $engineDir
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue

    $fileCount = (Get-ChildItem -Path $engineDir -Recurse -File).Count
    Write-Ok "$Repo@$Tag  ${sizeMb} MB, $fileCount files, revision $sha"
    return $sha
}

# ---------------------------------------------------------------------------
function Invoke-EcrLogin {
    param([string] $Registry)
    Write-Step 'ECR login'
    if ($DryRun -or $SkipPush) { Write-Skip 'not logging in (dry run or -SkipPush)'; return }

    # The password comes from the instance role. It is piped straight into docker
    # login and never written down.
    $pw = (aws ecr get-login-password --region $Region) 2>&1
    if ($LASTEXITCODE -ne 0) { throw "aws ecr get-login-password failed: $pw" }
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = ("$pw" | & docker login --username AWS --password-stdin $Registry 2>&1 | Out-String)
    $loginExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($loginExit -ne 0) { throw "docker login failed: $($out.Trim())" }
    Write-Ok "logged in to $Registry"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
$results = New-Object System.Collections.ArrayList

try {
    Test-Prerequisites
    $planPath = Resolve-PlanFile
    Write-Ok "plan: $planPath"
    $matrix   = Get-BuildMatrix -Path $planPath
    $registry = Get-EcrRegistry

    # Only fetch a token if there is actually something to download.
    $token = $null

    Invoke-EcrLogin -Registry $registry

    foreach ($item in $matrix) {
        $repoName = "$EcrNamespace/$($item.ImageFamily)"
        $imageRef = "$registry/${repoName}:$($item.Tag)"

        Write-Step "$($item.ImageFamily):$($item.Tag)"

        Confirm-EcrRepository -RepoName $repoName

        $exists = (-not $DryRun) -and (Test-ImageExists -RepoName $repoName -Tag $item.Tag)

        if ($exists -and (-not $Force)) {
            Write-Skip "$imageRef already in ECR - nothing to build. Use -Force to rebuild."
            $null = $results.Add([pscustomobject]@{ Image = "$($item.ImageFamily):$($item.Tag)"; Result = 'exists'; Revision = '-' })
            continue
        }

        if ($exists -and $Force -and (-not $SkipPush)) {
            # The repository is created with IMMUTABLE tags on purpose, so a push
            # over an existing tag WILL be rejected. Say so here rather than let
            # the build run for several minutes and fail at the last step.
            throw @"
$imageRef already exists and ECR tags are immutable, so -Force cannot overwrite it.

That immutability is deliberate: an engine tag is a released build, and if a tag
could be replaced then two runs could use different code under one name - which
would surface as a replay mismatch, not as an error.

If the existing image is genuinely wrong, delete the tag first and re-run:
  aws ecr batch-delete-image --repository-name $repoName --image-ids imageTag=$($item.Tag) --region $Region

To rebuild locally without pushing, add -SkipPush.
"@
        }

        if ($DryRun) {
            Write-Skip "would build $imageRef from $($item.EngineRepo)@$($item.Tag) using $($item.Context)\Dockerfile"
            $null = $results.Add([pscustomobject]@{ Image = "$($item.ImageFamily):$($item.Tag)"; Result = 'dry-run'; Revision = '-' })
            continue
        }

        if (-not $token) { $token = Get-GitHubToken }

        $sha = Get-EngineSource -Repo $item.EngineRepo -Tag $item.Tag -Token $token -ContextDir $item.Context

        Write-Host "  building $imageRef"
        docker build `
            --file (Join-Path $item.Context 'Dockerfile') `
            --tag $imageRef `
            --build-arg "ENGINE_REPO=$($item.EngineRepo)" `
            --build-arg "ENGINE_TAG=$($item.Tag)" `
            --build-arg "SOURCE_COMMIT=$sha" `
            --build-arg "BINARY=$($item.Binary)" `
            $item.Context
        if ($LASTEXITCODE -ne 0) { throw "docker build failed for $imageRef" }
        Write-Ok "built $imageRef"

        # The extracted engine tree is multi-GB in some repos. Do not leave it in
        # the build context: the next build would upload it again as context.
        Remove-Item -Recurse -Force (Join-Path $item.Context 'engine') -ErrorAction SilentlyContinue

        if ($SkipPush) {
            Write-Skip 'not pushing (-SkipPush)'
            $null = $results.Add([pscustomobject]@{ Image = "$($item.ImageFamily):$($item.Tag)"; Result = 'built'; Revision = $sha })
            continue
        }

        docker push $imageRef
        if ($LASTEXITCODE -ne 0) { throw "docker push failed for $imageRef" }
        Write-Ok "pushed $imageRef"
        $null = $results.Add([pscustomobject]@{ Image = "$($item.ImageFamily):$($item.Tag)"; Result = 'pushed'; Revision = $sha })
    }
}
catch {
    Write-Host ''
    Write-Fail $_.Exception.Message
    if ($results.Count -gt 0) {
        Write-Host ''
        Write-Host 'Completed before the failure:'
        $results | Format-Table -AutoSize | Out-String | Write-Host
    }
    exit 1
}

Write-Host ''
Write-Host '=== summary ===' -ForegroundColor Cyan
$results | Format-Table -AutoSize | Out-String | Write-Host

Write-Host 'Next:'
Write-Host '  1. Build the Linux hub image on the AlmaLinux host: ./build-images.sh'
Write-Host '  2. Deliver config with run-engine.ps1 (create -> cp -> start). The engine reads'
Write-Host '     its config from its own directory and has no config-path argument, so a mount'
Write-Host '     will not work - see images/README.md.'
Write-Host '  3. The console constraint is ANSWERED for the runtime (probed 2026-08-31: handler'
Write-Host '     registered, no event in 120s, all four container shapes survived). Confirm it for'
Write-Host '     the engine itself with:  test-oe-console.ps1 -Mode image -Image <ref> -ConfigDir <dir>'
Write-Host '  4. Images are immutable in ECR and outlive the stack, so this only reruns when'
Write-Host '     a flow names a tag that has not been built yet.'
