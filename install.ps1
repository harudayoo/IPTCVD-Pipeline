# Windows entry point for install.sh -- runs it under Git Bash (never WSL's bash).
# Usage and options are identical to install.sh:  .\install.ps1 --help
# Execution policy blocking it?  powershell -ExecutionPolicy Bypass -File .\install.ps1 ...
. (Join-Path $PSScriptRoot 'lib\win-bash.ps1')
Invoke-PipelineScript -Script (Join-Path $PSScriptRoot 'install.sh') -Arguments $args
