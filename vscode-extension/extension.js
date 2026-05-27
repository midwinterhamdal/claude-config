const vscode = require('vscode');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const CACHE_FILE  = path.join(os.homedir(), '.claude', 'statusline-cache.json');
const POLLER_FILE = path.join(os.homedir(), '.claude', 'usage-poller.ps1');
const POLL_MS = 2000;

function triggerPoller() {
  spawn('pwsh', ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', POLLER_FILE], {
    detached: true,
    stdio: 'ignore',
  }).unref();
}

function activate(context) {
  const item = vscode.window.createStatusBarItem('claude-usage.main', vscode.StatusBarAlignment.Right, 1000);

  // reset 감지용: 마지막으로 리셋 이벤트를 트리거한 타임스탬프 기록
  let lastReset5hTs  = null;
  let lastResetWkTs  = null;

  function minsUntil(ts) {
    if (ts == null) return null;
    return Math.round((ts - Date.now() / 1000) / 60);
  }

  function fmtMins(m) {
    if (m == null) return '?';
    if (m <= 0)    return '곧 초기화';
    if (m < 60)    return `${m}분`;
    const days  = Math.floor(m / 1440);
    const hours = Math.floor((m % 1440) / 60);
    const mins  = m % 60;
    if (days > 0) {
      return [`${days}d`, `${hours}h`, ...(mins > 0 ? [`${mins}m`] : [])].join(' ');
    }
    return `${hours}h${mins > 0 ? ` ${mins}m` : ''}`;
  }

  function update() {
    item.show();

    try {
      if (!fs.existsSync(CACHE_FILE)) {
        item.text = '$(circle-outline) Claude';
        item.backgroundColor = undefined;
        return;
      }

      const data = JSON.parse(fs.readFileSync(CACHE_FILE, 'utf8'));

      // ── 리셋 감지 → poller 자동 트리거 ──────────────────────────────────
      const now = Date.now() / 1000;
      const ts5h = data.tokens_5h_reset_ts;
      const tsWk = data.tokens_weekly_reset_ts;

      if (ts5h != null && now >= ts5h && lastReset5hTs !== ts5h) {
        lastReset5hTs = ts5h;
        triggerPoller();
      }
      if (tsWk != null && now >= tsWk && lastResetWkTs !== tsWk) {
        lastResetWkTs = tsWk;
        triggerPoller();
      }

      // ── 표시 ─────────────────────────────────────────────────────────────
      const used = data.context_used_tokens || 0;
      const max  = data.context_max_tokens  || 0;
      const pct  = max > 0 ? used / max : 0;
      const ctxStr = max > 0
        ? `${Math.round(used / 1000)}k/${Math.round(max / 1000)}k`
        : '—';

      const pct5h  = data.tokens_5h_pct;
      const pctWk  = data.tokens_weekly_pct;
      const acctPct = data.account_pct;

      const str5h   = pct5h  != null ? ` · 5h:${Math.round(pct5h)}%`   : '';
      const strWk   = pctWk  != null ? ` · 7d:${Math.round(pctWk)}%`   : '';
      const strAcct = (acctPct != null && pct5h == null && pctWk == null)
        ? ` · acct:${Math.round(acctPct)}%` : '';

      const model = (data.model || '').replace(/^claude-/, '').replace(/-\d{8}$/, '');
      const modelStr = model ? ` [${model}]` : '';

      item.text = `$(pulse) ${ctxStr}${str5h}${strWk}${strAcct}${modelStr}`;

      // ── Tooltip ───────────────────────────────────────────────────────────
      const lines = ['Claude 사용량', `  ctx: ${ctxStr} (현재 세션)`];
      if (pct5h != null) lines.push(`  5h:  ${pct5h}%  (리셋까지 ${fmtMins(minsUntil(ts5h))})`);
      if (pctWk  != null) lines.push(`  7d:  ${pctWk}%  (리셋까지 ${fmtMins(minsUntil(tsWk))})`);
      item.tooltip = lines.join('\n');

      // ── 배경색 ────────────────────────────────────────────────────────────
      const worstPct = Math.max(pct * 100, pct5h ?? 0, pctWk ?? 0, acctPct ?? 0);
      if (worstPct >= 90) {
        item.backgroundColor = new vscode.ThemeColor('statusBarItem.errorBackground');
      } else if (worstPct >= 75) {
        item.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
      } else {
        item.backgroundColor = undefined;
      }

    } catch (_) {
      item.text = '$(circle-slash) Claude: err';
      item.backgroundColor = undefined;
    }
  }

  update();
  const timer = setInterval(update, POLL_MS);

  context.subscriptions.push(item, { dispose: () => clearInterval(timer) });
}

function deactivate() {}

module.exports = { activate, deactivate };
