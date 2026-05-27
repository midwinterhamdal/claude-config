# install-usage-monitor.ps1
#
# 새 컴퓨터에서 Claude Code에게 이렇게 말하면 됩니다:
#   "GitHub midwinterhamdal/claude-config 레포의 install-usage-monitor.ps1을 클론해서 실행해줘"

param()
$ErrorActionPreference = "Stop"

$repo_url   = "https://github.com/midwinterhamdal/claude-config.git"
$temp_dir   = "$env:TEMP\claude-config-setup"
$claude_dir = "$env:USERPROFILE\.claude"
$ext_dir    = "$env:USERPROFILE\.vscode\extensions\claude-usage-0.0.1"

Write-Host "Claude Code usage monitor 설치 시작..."

# ── 1. 최신 버전 클론 ──────────────────────────────────────────────────────────
if (Test-Path $temp_dir) { Remove-Item $temp_dir -Recurse -Force }
Write-Host "[다운로드] $repo_url"
git clone $repo_url $temp_dir --depth 1 --quiet

# ── 2. Claude Code 스크립트 복사 ───────────────────────────────────────────────
New-Item -ItemType Directory -Path $claude_dir -Force | Out-Null
Copy-Item "$temp_dir\usage-poller.ps1"       "$claude_dir\usage-poller.ps1"       -Force
Copy-Item "$temp_dir\statusline-command.ps1" "$claude_dir\statusline-command.ps1" -Force
Write-Host "[설치] usage-poller.ps1, statusline-command.ps1"

# ── 3. VS Code extension 설치 ──────────────────────────────────────────────────
New-Item -ItemType Directory -Path $ext_dir -Force | Out-Null
Copy-Item "$temp_dir\vscode-extension\extension.js"  "$ext_dir\extension.js"  -Force
Copy-Item "$temp_dir\vscode-extension\package.json"  "$ext_dir\package.json"  -Force
Write-Host "[설치] VS Code extension"

# ── 4. settings.json 업데이트 ──────────────────────────────────────────────────
$settings_path = "$claude_dir\settings.json"

if (Test-Path $settings_path) {
    try   { $settings = Get-Content $settings_path -Raw | ConvertFrom-Json }
    catch { $settings = [PSCustomObject]@{} }
} else {
    $settings = [PSCustomObject]@{}
}

# statusLine — $env:USERPROFILE는 statusLine 컨텍스트에서 정상 동작
$settings | Add-Member -NotePropertyName "statusLine" -NotePropertyValue ([PSCustomObject]@{
    type    = "command"
    command = 'pwsh -NoProfile -NonInteractive -Command "& \"$env:USERPROFILE\.claude\statusline-command.ps1\""'
}) -Force

# hooks
if (-not $settings.PSObject.Properties["hooks"]) {
    $settings | Add-Member -NotePropertyName "hooks" -NotePropertyValue ([PSCustomObject]@{}) -Force
}

# Stop / UserPromptSubmit — [Environment]::GetEnvironmentVariable 방식으로 경로 해결
# ($env:USERPROFILE 가 이 컨텍스트에서 $env 부분이 날아가는 버그 우회)
$hook_cmd = 'pwsh -NoProfile -NonInteractive -Command "& ([Environment]::GetEnvironmentVariable(''USERPROFILE'') + ''\.claude\usage-poller.ps1'')"'

$settings.hooks | Add-Member -NotePropertyName "Stop" -NotePropertyValue @(
    [PSCustomObject]@{
        matcher = ""
        hooks   = @([PSCustomObject]@{ type = "command"; command = $hook_cmd; timeout = 30 })
    }
) -Force

$settings.hooks | Add-Member -NotePropertyName "UserPromptSubmit" -NotePropertyValue @(
    [PSCustomObject]@{
        hooks = @([PSCustomObject]@{ type = "command"; command = $hook_cmd; timeout = 30 })
    }
) -Force

$settings | ConvertTo-Json -Depth 10 | Set-Content $settings_path -Encoding UTF8
Write-Host "[설정] settings.json (statusLine + Stop + UserPromptSubmit)"

# ── 5. 정리 ────────────────────────────────────────────────────────────────────
Remove-Item $temp_dir -Recurse -Force

Write-Host ""
Write-Host "설치 완료! Claude Code를 재시작하면 statusline이 활성화됩니다."
