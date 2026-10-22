<#
.SYNOPSIS
    Review a pull request locally: fetch it into an isolated worktree, run the repo gates, and report.

.DESCRIPTION
    Pulls refs/pull/<n>/head into a dedicated worktree under .review/ so the reviewer's own branch
    stays untouched, then runs the checks this repository requires before a merge: backend
    lint + typecheck + tests, frontend typecheck when the dashboard changed, and an optional
    Docker build smoke test.

    This file is ASCII-only on purpose: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so
    non-ASCII text would break parsing.

    Exit codes: 0 every executed check passed; 1 at least one check failed; 2 usage or environment
    problem (missing git, gh, uv, or an invalid PR reference).

.PARAMETER Pr
    Pull request number.

.PARAMETER Repo
    owner/name of the GitHub repository.

.PARAMETER Root
    Repository root. Defaults to the working tree containing the current directory.

.PARAMETER SkipTests
    Only fetch and show the diff; skip every build and test step.

.PARAMETER Docker
    Additionally build the Docker image and verify the container answers /api/health.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/review-pr.ps1 -Pr 12

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/review-pr.ps1 -Pr 12 -SkipTests
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$Pr,
    [string]$Repo = 'Nemo7748/Octop',
    [string]$Root = '',
    [switch]$SkipTests,
    [switch]$Docker
)

$ErrorActionPreference = 'Continue'
$script:failures = @()
$script:results = @()

function Add-Result {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:results += [pscustomobject]@{ Check = $Name; Status = $Status; Detail = $Detail }
    if ($Status -eq 'FAIL') { $script:failures += $Name }
}

function Test-Tool {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $true }
    return $false
}

function Invoke-Step {
    param([string]$Name, [string]$Exe, [string[]]$StepArgs, [string]$WorkDir)
    Write-Output ''
    Write-Output "--- $Name ---"
    Write-Output ("    " + $Exe + " " + ($StepArgs -join ' '))
    Push-Location -LiteralPath $WorkDir
    try {
        & $Exe @StepArgs 2>&1 | ForEach-Object { Write-Output $_ }
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if ($code -eq 0) {
        Add-Result $Name 'PASS'
        Write-Output "    => PASS"
    }
    else {
        Add-Result $Name 'FAIL' "exit $code"
        Write-Output "    => FAIL (exit $code)"
    }
    return $code
}

# ---------------------------------------------------------------- environment
if (-not (Test-Tool 'git')) {
    Write-Output 'git is not available on PATH.'
    exit 2
}

if ($Root) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
        Write-Output "Not a git working tree: $Root"
        exit 2
    }
    $repoRoot = (Resolve-Path -LiteralPath $Root).Path
}
else {
    $repoRoot = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $repoRoot) {
        Write-Output 'Not inside a git working tree. Pass -Root <path> to the Octop checkout.'
        exit 2
    }
}
Write-Output "repository : $repoRoot"
Write-Output "pull request: $Repo#$Pr"

# ---------------------------------------------------------------- fetch + metadata
$branch = "review/pr-$Pr"
$worktree = Join-Path $repoRoot (Join-Path '.review' "pr-$Pr")

Write-Output ''
Write-Output '--- fetch PR head ---'
& git -C $repoRoot fetch origin "pull/$Pr/head:$branch" --force
if ($LASTEXITCODE -ne 0) {
    Write-Output "Could not fetch refs/pull/$Pr/head. Check the PR number and that it belongs to $Repo."
    exit 2
}
Add-Result 'fetch' 'PASS'

if (Test-Path -LiteralPath $worktree) {
    & git -C $repoRoot worktree remove --force $worktree 2>$null | Out-Null
    if (Test-Path -LiteralPath $worktree) { Remove-Item -LiteralPath $worktree -Recurse -Force }
}
& git -C $repoRoot worktree add --force $worktree $branch
if ($LASTEXITCODE -ne 0) {
    Write-Output 'Could not create the review worktree.'
    exit 2
}
Add-Result 'worktree' 'PASS' $worktree

Write-Output ''
Write-Output '--- change summary ---'
& git -C $worktree diff --stat "origin/main...HEAD"
$changed = @(& git -C $worktree diff --name-only "origin/main...HEAD")
Write-Output ''
Write-Output ("changed files: " + $changed.Count)
& git -C $worktree log --oneline "origin/main..HEAD"

$touchesDashboard = @($changed | Where-Object { $_ -like 'dashboard/*' }).Count -gt 0
$touchesDocs = @($changed | Where-Object { $_ -like 'docs/*' }).Count -gt 0
$touchesDocker = @($changed | Where-Object { $_ -like 'docker/*' -or $_ -like 'Dockerfile' }).Count -gt 0
Write-Output ''
Write-Output ("touches dashboard: $touchesDashboard")
Write-Output ("touches docs     : $touchesDocs")
Write-Output ("touches docker   : $touchesDocker")

# ---------------------------------------------------------------- CI status
# The repository ships .github/workflows/ci.yml, but a fork does not run workflows until an
# administrator enables them. Zero checks therefore means "not verified", never "verified green".
if (Test-Tool 'gh') {
    $raw = & gh pr view $Pr --repo $Repo --json statusCheckRollup,reviewDecision,mergeStateStatus 2>$null | Out-String
    if ($LASTEXITCODE -eq 0 -and $raw.Trim()) {
        $meta = $raw | ConvertFrom-Json
        $checks = @($meta.statusCheckRollup)
        Write-Output ''
        Write-Output ("--- CI status: {0} check(s), review={1} ---" -f $checks.Count, $meta.reviewDecision)
        if ($checks.Count -eq 0) {
            Write-Output '    no checks reported: workflows are not enabled on this repository.'
            Add-Result 'ci' 'WARN' 'no checks reported (fork workflows not enabled)'
        }
        else {
            foreach ($c in $checks) {
                if ($c.conclusion) { $state = $c.conclusion } else { $state = $c.status }
                Write-Output ("    {0} {1}" -f $state, $c.name)
            }
            $failed = @($checks | Where-Object { $_.conclusion -and $_.conclusion -notin @('SUCCESS', 'NEUTRAL', 'SKIPPED') })
            $pending = @($checks | Where-Object { $_.status -ne 'COMPLETED' })
            if ($failed.Count -gt 0) {
                Add-Result 'ci' 'FAIL' ("$($failed.Count) failing check(s)")
            }
            elseif ($pending.Count -gt 0) {
                Add-Result 'ci' 'FAIL' ("$($pending.Count) check(s) still running")
            }
            else {
                Add-Result 'ci' 'PASS' ("$($checks.Count) check(s) green")
            }
        }
    }
}
else {
    Add-Result 'ci' 'WARN' 'gh is not available; CI status not inspected'
}

if ($SkipTests) {
    Write-Output ''
    Write-Output 'SkipTests requested: diff only. No build or test step was executed.'
    exit 0
}

# ---------------------------------------------------------------- backend gates
if (Test-Tool 'uv') {
    Invoke-Step 'backend: make all (lint + typecheck + test)' 'make' @('all') $worktree | Out-Null
}
else {
    Add-Result 'backend: make all' 'SKIP' 'uv is not installed on this machine'
    Write-Output ''
    Write-Output 'uv is missing: see the environment setup section in docs/team/.'
}

# ---------------------------------------------------------------- frontend gates
if ($touchesDashboard) {
    if (Test-Tool 'npm') {
        if (-not (Test-Path -LiteralPath (Join-Path $worktree 'dashboard\node_modules'))) {
            Invoke-Step 'dashboard: npm ci' 'npm' @('ci') (Join-Path $worktree 'dashboard') | Out-Null
        }
        Invoke-Step 'dashboard: tsc --noEmit' 'npx' @('tsc', '--noEmit') (Join-Path $worktree 'dashboard') | Out-Null
    }
    else {
        Add-Result 'dashboard: tsc --noEmit' 'SKIP' 'npm is not installed on this machine'
    }
}
else {
    Add-Result 'dashboard: tsc --noEmit' 'SKIP' 'no dashboard/ changes'
}

# ---------------------------------------------------------------- i18n parity
if (@($changed | Where-Object { $_ -like '*i18n/*' -or $_ -like '*locales/*' }).Count -gt 0) {
    if (Test-Tool 'uv') {
        Invoke-Step 'i18n key parity' 'uv' @('run', 'pytest', 'tests/unit/i18n', '-q') $worktree | Out-Null
    }
}

# ---------------------------------------------------------------- docker smoke
if ($Docker -or $touchesDocker) {
    if (Test-Tool 'docker') {
        Invoke-Step 'docker build' 'docker' @('build', '-f', 'docker/Dockerfile', '-t', "octop:review-$Pr", '.') $worktree | Out-Null

        Write-Output ''
        Write-Output '--- docker run smoke ---'
        & docker rm -f "octop-review-$Pr" 2>$null | Out-Null
        & docker run -d --name "octop-review-$Pr" -p 18088:8088 "octop:review-$Pr" | Out-Null
        $ok = $false
        foreach ($attempt in 1..30) {
            Start-Sleep -Seconds 2
            try {
                $resp = Invoke-WebRequest -Uri 'http://127.0.0.1:18088/api/health' -UseBasicParsing -TimeoutSec 5
                if ($resp.StatusCode -eq 200) { $ok = $true; break }
            }
            catch { }
        }
        if ($ok) { Add-Result 'docker: /api/health' 'PASS' }
        else {
            Add-Result 'docker: /api/health' 'FAIL' 'no 200 within 60s'
            Write-Output '--- container logs (tail) ---'
            & docker logs --tail 60 "octop-review-$Pr" 2>&1 | ForEach-Object { Write-Output $_ }
        }
        & docker rm -f "octop-review-$Pr" 2>$null | Out-Null
    }
    else {
        Add-Result 'docker smoke' 'SKIP' 'Docker is not installed on this machine'
    }
}

# ---------------------------------------------------------------- report
Write-Output ''
Write-Output '================ REVIEW REPORT ================'
$script:results | Format-Table -AutoSize Check, Status, Detail | Out-String | Write-Output

if ($script:failures.Count -gt 0) {
    Write-Output ("VERDICT: REQUEST CHANGES - failed: " + ($script:failures -join ', '))
    Write-Output "Worktree kept for inspection: $worktree"
    exit 1
}

$skipped = @($script:results | Where-Object { $_.Status -eq 'SKIP' }).Count
if ($skipped -gt 0) {
    Write-Output ("VERDICT: INCOMPLETE - $skipped check(s) skipped; do not merge until they run.")
    exit 1
}

$warnings = @($script:results | Where-Object { $_.Status -eq 'WARN' })
if ($warnings.Count -gt 0) {
    foreach ($w in $warnings) { Write-Output ("WARNING: {0} - {1}" -f $w.Check, $w.Detail) }
    Write-Output 'VERDICT: APPROVE WITH WARNINGS - read the warnings before merging; unverified items are listed above.'
    Write-Output "Worktree: $worktree"
    exit 0
}

Write-Output 'VERDICT: APPROVE - every executed check passed.'
Write-Output "Worktree: $worktree"
exit 0
