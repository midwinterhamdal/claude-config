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
