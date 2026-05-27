# install-usage-monitor.ps1
# Claude Code 사용량 모니터 설치 스크립트
# 새 컴퓨터에서 Claude Code에게: "이 스크립트를 실행해줘" 또는
# 직접 실행: pwsh -File install-usage-monitor.ps1

param()
$ErrorActionPreference = "Stop"
$claude_dir = "$env:USERPROFILE\.claude"

Write-Host "Claude Code 사용량 모니터 설치 시작..."
Write-Host "설치 경로: $claude_dir"
Write-Host ""

# .claude 디렉토리 생성
if (-not (Test-Path $claude_dir)) {
    New-Item -ItemType Directory -Path $claude_dir -Force | Out-Null
    Write-Host "[생성] $claude_dir"
}

# ── usage-poller.ps1 ──────────────────────────────────────────────────────────
Set-Content "$claude_dir\usage-poller.ps1" -Encoding UTF8 -Value @'
# usage-poller.ps1 — Anthropic rate-limit 헤더에서 계정 사용량을 읽어 statusline cache에 씀

param()

$cred_file  = "$env:USERPROFILE\.claude\.credentials.json"
$cache_file = "$env:USERPROFILE\.claude\statusline-cache.json"
$log_file   = "$env:USERPROFILE\.claude\poller.log"

function Log($msg) {
    $ts = Get-Date -Format 'HH:mm:ss'
    Add-Content $log_file "$ts $msg" -Encoding UTF8
}

Log "START"

# ── 인증 토큰 읽기 ────────────────────────────────────────────────────────────
try {
    $creds = Get-Content $cred_file -Raw -ErrorAction Stop | ConvertFrom-Json
    $token = $creds.claudeAiOauth.accessToken
    if (-not $token) { Log "ERR: no token"; exit 1 }
} catch { Log "ERR: creds read failed - $_"; exit 1 }

# ── 최소 비용 API 호출로 rate-limit 헤더 수집 ──────────────────────────────
$req_headers = @{
    Authorization        = "Bearer $token"
    "anthropic-version"  = "2023-06-01"
    "Content-Type"       = "application/json"
}
$body = '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"1"}]}'

try {
    $r = Invoke-WebRequest -Uri "https://api.anthropic.com/v1/messages" `
         -Headers $req_headers -Method POST -Body $body -TimeoutSec 20 -ErrorAction Stop
} catch {
    Log "ERR: API call failed [$($_.Exception.Response.StatusCode)] - $_"
    exit 1
}

$h = $r.Headers

# ── 헤더 파싱 ────────────────────────────────────────────────────────────────
function Get-Header($name) {
    return @($h[$name])[0]
}

$util5h  = Get-Header "anthropic-ratelimit-unified-5h-utilization"
$util7d  = Get-Header "anthropic-ratelimit-unified-7d-utilization"
$reset5h = Get-Header "anthropic-ratelimit-unified-5h-reset"
$reset7d = Get-Header "anthropic-ratelimit-unified-7d-reset"
$status  = Get-Header "anthropic-ratelimit-unified-status"

$pct5h = if ($util5h)  { [math]::Round([double]$util5h * 100, 1) } else { $null }
$pct7d = if ($util7d)  { [math]::Round([double]$util7d * 100, 1) } else { $null }

function Mins-Until($unix) {
    if (-not $unix) { return $null }
    $diff = [long]$unix - [long](Get-Date -UFormat %s)
    if ($diff -le 0) { return 0 }
    return [math]::Round($diff / 60)
}

$reset5h_mins = Mins-Until $reset5h
$reset7d_mins = Mins-Until $reset7d

# ── 기존 캐시의 context window / model 유지 ─────────────────────────────────
$ctx_used  = $null
$ctx_max   = $null
$model_str = $null
if (Test-Path $cache_file) {
    try {
        $old = Get-Content $cache_file -Raw | ConvertFrom-Json
        $ctx_used  = $old.context_used_tokens
        $ctx_max   = $old.context_max_tokens
        $model_str = $old.model
    } catch {}
}

# ── 캐시 파일 업데이트 ────────────────────────────────────────────────────────
$cache = [ordered]@{
    context_used_tokens     = $ctx_used
    context_max_tokens      = $ctx_max
    tokens_5h_pct           = $pct5h
    tokens_5h_reset_ts      = if ($reset5h)  { [long]$reset5h }  else { $null }
    tokens_weekly_pct       = $pct7d
    tokens_weekly_reset_ts  = if ($reset7d)  { [long]$reset7d }  else { $null }
    rate_limit_status       = $status
    account_pct             = $null
    model                   = $model_str
    updated_at              = (Get-Date -Format 'o')
    rate_limit_updated_at   = (Get-Date -Format 'o')
}

try {
    $cache | ConvertTo-Json -Depth 5 -Compress | Set-Content $cache_file -Encoding UTF8
    Log "OK: 5h=$pct5h% 7d=$pct7d%"
} catch { Log "ERR: cache write failed - $_"; exit 1 }
'@
Write-Host "[설치] usage-poller.ps1"

# ── statusline-command.ps1 ────────────────────────────────────────────────────
Set-Content "$claude_dir\statusline-command.ps1" -Encoding UTF8 -Value @'
param()
$log_file = "$env:USERPROFILE\.claude\statusline.log"
function SLog($msg) { Add-Content $log_file "$(Get-Date -Format 'HH:mm:ss') $msg" -Encoding UTF8 }

# stdin pipe가 닫히지 않는 경우 무한 블로킹 방지 — 3초 타임아웃
# 타임아웃/파싱 실패 시에도 캐시 기반으로 statusline 출력 + 폴러 트리거는 항상 실행
$stdin = [Console]::OpenStandardInput()
$reader = [System.IO.StreamReader]::new($stdin)
$task = $reader.ReadToEndAsync()
$gotStdin = $task.Wait(500)
$raw = if ($gotStdin) { $task.Result } else { "" }

$data = $null
if ($raw.Trim()) {
    SLog "RUN"
    try { $data = $raw | ConvertFrom-Json } catch { SLog "WARN: json parse failed" }
} else {
    SLog "SKIP: $(if ($gotStdin) { 'empty stdin' } else { 'stdin timeout' })"
}

$cwd   = if ($data) { $data.cwd }   else { $PWD.Path }
$model = if ($data) { $data.model.display_name } else { $null }
$used  = if ($data) { $data.context_window.used_tokens } else { $null }
$max   = if ($data) { $data.context_window.max_tokens }  else { $null }

# Shorten home directory
$home_dir = $env:USERPROFILE
if ($cwd -and $home_dir) {
    $short_cwd = $cwd -replace [regex]::Escape($home_dir), '~'
} else {
    $short_cwd = $cwd
}

# Git branch + dirty indicator
$branch = ""
$dirty  = ""
if ($cwd -and (Test-Path $cwd)) {
    try {
        $branch = & git -C $cwd --no-optional-locks symbolic-ref --short HEAD 2>$null
        if ($LASTEXITCODE -ne 0) { $branch = "" }
        if ($branch) {
            $status = & git -C $cwd --no-optional-locks status --porcelain 2>$null
            if ($status) { $dirty = "*" }
        }
    } catch { $branch = ""; $dirty = "" }
}

# Token usage as "23k/200k"
$token_str = ""
if ($max -gt 0 -and $null -ne $used) {
    $used_k = [math]::Round([double]$used / 1000)
    $max_k  = [math]::Round([double]$max  / 1000)
    $token_str = "${used_k}k/${max_k}k"
}

# Current time
$time_str = Get-Date -Format "HH:mm"

# Build parts
$parts = @()
if ($short_cwd)  { $parts += $short_cwd }
if ($branch)     { $parts += "[$branch$dirty]" }
if ($model)      { $parts += $model }
if ($token_str)  { $parts += $token_str }
$parts += $time_str

Write-Output ($parts -join " | ")

# ── VS Code status bar bridge ──────────────────────────────────────────────
function Get-NestedValue {
    param($obj, [string[]]$paths)
    foreach ($p in $paths) {
        $parts = $p -split '\.'
        $cur = $obj
        foreach ($part in $parts) {
            if ($null -eq $cur) { $cur = $null; break }
            $cur = $cur.$part
        }
        if ($null -ne $cur) { return $cur }
    }
    return $null
}

function Calc-Pct($used, $limit) {
    if ($null -ne $used -and $null -ne $limit -and [double]$limit -gt 0) {
        return [math]::Round(([double]$used / [double]$limit) * 100, 1)
    }
    return $null
}

$u5h = Get-NestedValue $data @(
    'usage.tokens_5h_used', 'usage.tokens_5h', 'usage.input_tokens_5h',
    'limits.tokens_5h.used', 'limits.tokens_5h_used',
    'billing.tokens_5h_used', 'billing.tokens_5h',
    'rate_limit.tokens_5h_used', 'rate_limit.used_5h',
    'token_usage.used_5h', 'token_usage.tokens_5h'
)
$l5h = Get-NestedValue $data @(
    'usage.tokens_5h_limit', 'usage.input_tokens_5h_limit',
    'limits.tokens_5h.limit', 'limits.tokens_5h_limit',
    'billing.tokens_5h_limit',
    'rate_limit.tokens_5h_limit', 'rate_limit.limit_5h',
    'token_usage.limit_5h', 'token_usage.tokens_5h_limit'
)
$tokens_5h_pct = Calc-Pct $u5h $l5h

$uwk = Get-NestedValue $data @(
    'usage.tokens_weekly_used', 'usage.tokens_weekly', 'usage.input_tokens_weekly',
    'limits.tokens_weekly.used', 'limits.tokens_weekly_used',
    'billing.tokens_weekly_used', 'billing.tokens_weekly',
    'rate_limit.tokens_weekly_used', 'rate_limit.used_weekly',
    'token_usage.used_weekly', 'token_usage.tokens_weekly'
)
$lwk = Get-NestedValue $data @(
    'usage.tokens_weekly_limit', 'usage.input_tokens_weekly_limit',
    'limits.tokens_weekly.limit', 'limits.tokens_weekly_limit',
    'billing.tokens_weekly_limit',
    'rate_limit.tokens_weekly_limit', 'rate_limit.limit_weekly',
    'token_usage.limit_weekly', 'token_usage.tokens_weekly_limit'
)
$tokens_weekly_pct = Calc-Pct $uwk $lwk

$acct_pct = $null
if ($null -ne $data.account_usage) {
    $acct_pct = $data.account_usage
} elseif ($null -ne $data.usage_percent) {
    $acct_pct = $data.usage_percent
} elseif ($null -ne $data.billing.used_percentage) {
    $acct_pct = $data.billing.used_percentage
}

$cache = [ordered]@{
    context_used_tokens = $used
    context_max_tokens  = $max
    tokens_5h_pct       = $tokens_5h_pct
    tokens_weekly_pct   = $tokens_weekly_pct
    account_pct         = $acct_pct
    model               = $model
    updated_at          = (Get-Date -Format 'o')
    _raw                = $data
}

$cache_path = "$env:USERPROFILE\.claude\statusline-cache.json"

if (Test-Path $cache_path) {
    try {
        $old = Get-Content $cache_path -Raw | ConvertFrom-Json
        if ($null -ne $old.tokens_5h_pct)          { $cache.tokens_5h_pct           = $old.tokens_5h_pct }
        if ($null -ne $old.tokens_5h_reset_ts)     { $cache.tokens_5h_reset_ts      = $old.tokens_5h_reset_ts }
        if ($null -ne $old.tokens_weekly_pct)      { $cache.tokens_weekly_pct       = $old.tokens_weekly_pct }
        if ($null -ne $old.tokens_weekly_reset_ts) { $cache.tokens_weekly_reset_ts  = $old.tokens_weekly_reset_ts }
        if ($null -ne $old.rate_limit_status)      { $cache.rate_limit_status       = $old.rate_limit_status }
        if ($null -eq $cache.model -and $null -ne $old.model) { $cache.model        = $old.model }
    } catch {}
}

try {
    $cache | ConvertTo-Json -Depth 10 -Compress | Set-Content $cache_path -Encoding UTF8
} catch {}

# ── 매 응답마다 rate limit 비동기 갱신 트리거 ────────────────────────────────
$poller = "$env:USERPROFILE\.claude\usage-poller.ps1"
if (Test-Path $poller) {
    Start-Process pwsh -ArgumentList "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$poller`"" -WindowStyle Hidden
}
'@
Write-Host "[설치] statusline-command.ps1"

# ── settings.json merge ───────────────────────────────────────────────────────
$settings_path = "$claude_dir\settings.json"

if (Test-Path $settings_path) {
    try {
        $settings = Get-Content $settings_path -Raw | ConvertFrom-Json
    } catch {
        Write-Host "[경고] settings.json 파싱 실패 — 새로 생성합니다"
        $settings = [PSCustomObject]@{}
    }
} else {
    $settings = [PSCustomObject]@{}
}

# statusLine 설정 (기존 값 덮어씀)
$settings | Add-Member -NotePropertyName "statusLine" -NotePropertyValue ([PSCustomObject]@{
    type    = "command"
    command = "pwsh -NoProfile -NonInteractive -File %USERPROFILE%\.claude\statusline-command.ps1"
}) -Force

# hooks 객체 없으면 생성
if (-not $settings.PSObject.Properties["hooks"]) {
    $settings | Add-Member -NotePropertyName "hooks" -NotePropertyValue ([PSCustomObject]@{}) -Force
}

# Stop hook 설정 (기존 값 덮어씀)
$stop_hook = [PSCustomObject]@{
    type    = "command"
    command = "pwsh -NoProfile -NonInteractive -File %USERPROFILE%\.claude\usage-poller.ps1"
    timeout = 30
}
$stop_entry = [PSCustomObject]@{
    matcher = ""
    hooks   = @($stop_hook)
}
$settings.hooks | Add-Member -NotePropertyName "Stop" -NotePropertyValue @($stop_entry) -Force

# UserPromptSubmit hook 설정 (기존 값 덮어씀)
# 주의: UserPromptSubmit에서 -File 방식은 동작 안 함 — -Command "&" 방식으로 우회
$poller_path = "$env:USERPROFILE\.claude\usage-poller.ps1"
$prompt_hook = [PSCustomObject]@{
    type    = "command"
    command = "pwsh -NoProfile -NonInteractive -Command `"& '$poller_path'`""
    timeout = 30
}
$prompt_entry = [PSCustomObject]@{
    hooks = @($prompt_hook)
}
$settings.hooks | Add-Member -NotePropertyName "UserPromptSubmit" -NotePropertyValue @($prompt_entry) -Force

$settings | ConvertTo-Json -Depth 10 | Set-Content $settings_path -Encoding UTF8
Write-Host "[설정] settings.json (statusLine + Stop + UserPromptSubmit hook)"

Write-Host ""
Write-Host "설치 완료!"
Write-Host "Claude Code를 재시작하면 하단 statusline이 활성화됩니다."
Write-Host "첫 사용량 업데이트는 대화를 시작하거나 세션 종료 시 자동으로 이루어집니다."
