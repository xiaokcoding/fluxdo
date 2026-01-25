#!/usr/bin/env pwsh
# FluxDO 发版脚本 (PowerShell)
# 用法: pwsh -File scripts/release.ps1 [版本号] [--pre]
# 示例: pwsh -File scripts/release.ps1 0.1.0
#       pwsh -File scripts/release.ps1 0.1.0-beta --pre

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Version,
    [Parameter(Position = 1)]
    [string]$Pre
)

function Write-Info {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-ErrorAndExit {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

$IsPrerelease = $false
if ($Pre -eq "--pre") {
    $IsPrerelease = $true
}

if ($Version -notmatch '^\d+\.\d+\.\d+(-[a-zA-Z0-9.]+)?$') {
    Write-ErrorAndExit "版本号格式错误，应为: x.y.z 或 x.y.z-beta"
}

$VersionName = ($Version -split "-")[0]

git rev-parse --git-dir > $null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-ErrorAndExit "当前目录不是 git 仓库"
}

git diff-index --quiet HEAD -- > $null 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-ErrorAndExit "存在未提交的更改，请先提交或暂存"
}

$CurrentBranch = (git branch --show-current).Trim()
if ($CurrentBranch -ne "main") {
    Write-Warn "当前不在 main 分支 (当前: $CurrentBranch)"
    $Continue = Read-Host "是否继续? (y/N)"
    if ($Continue -notin @("y", "Y")) {
        exit 1
    }
}

git rev-parse "v$Version" > $null 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-ErrorAndExit "Tag v$Version 已存在"
}

$PubspecPath = "pubspec.yaml"
if (-not (Test-Path $PubspecPath)) {
    Write-ErrorAndExit "找不到 pubspec.yaml 文件"
}

$CurrentVersionLine = Select-String -Path $PubspecPath -Pattern '^version:' | Select-Object -First 1
$CurrentVersion = ""
if ($CurrentVersionLine) {
    $CurrentVersion = ($CurrentVersionLine.Line -replace '^version:\s*', '') -replace '\+.*', ''
}

Write-Info "当前版本: $CurrentVersion"
Write-Info "新版本: $Version"

$VersionCode = Get-Date -Format "yyyyMMddHH"
Write-Info "Version Code: $VersionCode"

Write-Host ""
Write-Host "=========================================="
Write-Host "  发版信息"
Write-Host "=========================================="
Write-Host "版本号: $Version"
Write-Host "Version Name: $VersionName"
Write-Host "Version Code: $VersionCode"
Write-Host ("类型: " + ($(if ($IsPrerelease) { "预发布版" } else { "稳定版" })))
Write-Host "分支: $CurrentBranch"
Write-Host "=========================================="
Write-Host ""

$Confirm = Read-Host "确认发版? (y/N)"
if ($Confirm -notin @("y", "Y")) {
    Write-Info "已取消"
    exit 0
}

Write-Info "更新 pubspec.yaml..."
$Content = Get-Content $PubspecPath -Raw
$Content = $Content -replace '(?m)^version:.*$', "version: $VersionName+$VersionCode"
Set-Content -Path $PubspecPath -Value $Content -Encoding utf8

Write-Info "提交版本号变更..."
git add $PubspecPath
git commit -m "chore: bump version to $Version" -m "" -m "Co-Authored-By: Release Script <noreply@github.com>"

Write-Info "推送到远程仓库..."
git push

Write-Info "创建 tag v$Version..."
git tag -a "v$Version" -m "Release v$Version"

Write-Info "推送 tag..."
git push origin "v$Version"

Write-Host ""
Write-Host "=========================================="
Write-Host "✓ 发版成功!"
Write-Host "=========================================="
Write-Host "Tag: v$Version"
Write-Host "GitHub Actions: https://github.com/Lingyan000/fluxdo/actions"
Write-Host "Releases: https://github.com/Lingyan000/fluxdo/releases"
Write-Host "=========================================="
Write-Host ""

if ($IsPrerelease) {
    Write-Info "这是预发布版，不会生成 Changelog"
} else {
    Write-Info "稳定版会自动生成 Changelog 并提交到 main 分支"
}
