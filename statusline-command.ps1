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
