# Shared by install.ps1, configure.ps1 and verify.ps1: find Git Bash and run
# one of the pipeline's bash scripts through it from PowerShell or cmd.
#
# Why Git Bash specifically, and never the first `bash` on PATH: on Windows
# that is often C:\Windows\System32\bash.exe, the WSL launcher. It runs the
# script inside a Linux VM that sees the project as /mnt/c/..., installs hooks
# with paths that native Claude Code cannot run, and every check reports
# success from the wrong machine. Claude Code on Windows runs hooks through
# Git Bash too, so the installer must use the same bash the hooks will get.
#
# Windows PowerShell 5.1 compatible: no ?:, no ??, no &&.

function Find-GitBash {
    $candidates = @()
    # Claude Code's own setting for which bash to use; if it is set, the hooks
    # will run under exactly that bash, so the installer must as well.
    if ($env:CLAUDE_CODE_GIT_BASH_PATH) { $candidates += $env:CLAUDE_CODE_GIT_BASH_PATH }
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        # ...\Git\cmd\git.exe or ...\Git\mingw64\bin\git.exe -> ...\Git\bin\bash.exe
        $gitRoot = Split-Path (Split-Path $git.Source -Parent) -Parent
        $candidates += (Join-Path $gitRoot 'bin\bash.exe')
        $candidates += (Join-Path (Split-Path $gitRoot -Parent) 'bin\bash.exe')
    }
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'Git\bin\bash.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe') }
    if ($env:LOCALAPPDATA) { $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe') }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        if ($c -like '*\System32\bash.exe') { continue }   # WSL, never
        if (Test-Path -LiteralPath $c -PathType Leaf) { return (Resolve-Path -LiteralPath $c).ProviderPath }
    }
    return $null
}

# Invoke-PipelineScript <script.sh> <args...>
# Converts the values of --target and --home to absolute forward-slash paths
# (bash would read C:\x\y as an escape sequence), resolved against the
# PowerShell location -- which is NOT the process working directory a child
# inherits unless it is copied across first.
function Invoke-PipelineScript {
    param([string]$Script, [string[]]$Arguments)

    $bash = Find-GitBash
    if (-not $bash) {
        Write-Host 'error: Git Bash was not found.' -ForegroundColor Red
        Write-Host '  IPTCVD Pipeline runs its installer and its hooks under Git Bash, the same'
        Write-Host '  bash Claude Code uses for hooks on Windows. Install Git for Windows'
        Write-Host '  (https://git-scm.com/download/win), or set CLAUDE_CODE_GIT_BASH_PATH to'
        Write-Host '  your bash.exe, then run this again.'
        exit 1
    }

    [Environment]::CurrentDirectory = (Get-Location).ProviderPath

    $out = @()
    $i = 0
    while ($i -lt $Arguments.Count) {
        $a = $Arguments[$i]
        if (($a -eq '--target' -or $a -eq '--home') -and ($i + 1) -lt $Arguments.Count) {
            $v = $Arguments[$i + 1]
            if ($a -eq '--home' -and -not (Test-Path -LiteralPath $v)) {
                New-Item -ItemType Directory -Force -Path $v | Out-Null
            }
            $abs = (Resolve-Path -LiteralPath $v -ErrorAction Stop).ProviderPath
            $out += $a
            $out += ($abs -replace '\\', '/')
            $i += 2
            continue
        }
        $out += $a
        $i += 1
    }

    # $Script is a full path from the caller: inside a dot-sourced function,
    # $PSScriptRoot would name lib\, not the directory install.sh lives in.
    $scriptPath = $Script -replace '\\', '/'
    & $bash $scriptPath @out
    exit $LASTEXITCODE
}
