const chunks = [];
process.stdin.on('data', d => chunks.push(d));
process.stdin.on('end', () => {
  let data = {};
  try { data = JSON.parse(chunks.join('')); } catch (err) { console.error('statusline: JSON.parse failed:', err.message); }

  const reset  = '\x1b[0m';
  const dim    = '\x1b[2m';
  const bold   = '\x1b[1m';
  const green  = '\x1b[32m';
  const yellow = '\x1b[33m';
  const red    = '\x1b[31m';
  const cyan   = '\x1b[36m';
  const gray   = '\x1b[90m';

  function color(pct) {
    if (pct >= 80) return red;
    if (pct >= 50) return yellow;
    return green;
  }

  function bar(pct, width = 8) {
    const filled = Math.round((pct / 100) * width);
    return '█'.repeat(filled) + '░'.repeat(width - filled);
  }

  const parts = [];

  const modelName = data?.model?.display_name;
  const cost = data?.cost?.total_cost_usd;
  if (modelName || cost != null) {
    const shortName = modelName ? modelName.replace(/^Claude\s+/i, '') : null;
    const costStr = cost != null ? `${gray}$${Number(cost).toFixed(4)}${reset}` : null;
    const modelStr = shortName ? `${cyan}${shortName}${reset}` : null;
    const combined = [modelStr, costStr].filter(Boolean).join(`  `);
    if (combined) parts.push(combined);
  }

  const ctx = data?.context_window?.used_percentage;
  if (ctx != null) {
    const pct = Math.round(ctx);
    parts.push(`${gray}ctx${reset} ${color(pct)}${bar(pct)}${reset}${dim} ${pct}%${reset}`);
  }

  const r5h = data?.rate_limits?.five_hour?.used_percentage;
  const r5hResetsAt = data?.rate_limits?.five_hour?.resets_at;
  const r7d = data?.rate_limits?.seven_day?.used_percentage;
  const r7dResetsAt = data?.rate_limits?.seven_day?.resets_at;
  if (r5h != null || r7d != null) {
    let rateStr = `${gray}limits${reset}`;

    function countdownHMS(resetsAt) {
      const secsLeft = Math.max(0, Math.round(resetsAt - Date.now() / 1000));
      const hh = Math.floor(secsLeft / 3600);
      const mm = Math.floor((secsLeft % 3600) / 60);
      const ss = secsLeft % 60;
      return `${String(hh).padStart(2,'0')}:${String(mm).padStart(2,'0')}:${String(ss).padStart(2,'0')}`;
    }

    function countdownDH(resetsAt) {
      const secsLeft = Math.max(0, Math.round(resetsAt - Date.now() / 1000));
      const dd = Math.floor(secsLeft / 86400);
      const hh = Math.floor((secsLeft % 86400) / 3600);
      return `${dd}d ${String(hh).padStart(2,'0')}h`;
    }

    const block5h = [];
    const block7d = [];

    if (r5h != null) {
      const p = Math.round(r5h);
      block5h.push(`${dim}5h${reset} ${color(p)}${p}%${reset}`);
      if (r5hResetsAt != null) {
        block5h.push(`${dim}resets in${reset} ${color(p)}${countdownHMS(r5hResetsAt)}${reset}`);
      }
    }
    if (r7d != null) {
      const p = Math.round(r7d);
      block7d.push(`${dim}7d${reset} ${color(p)}${p}%${reset}`);
      if (r7dResetsAt != null) {
        block7d.push(`${dim}resets in${reset} ${color(p)}${countdownDH(r7dResetsAt)}${reset}`);
      }
    }

    const blocks = [];
    if (block5h.length) blocks.push(block5h.join(' '));
    if (block7d.length) blocks.push(block7d.join(' '));
    rateStr += ' ' + blocks.join(`  ${gray}|${reset}  `);
    parts.push(rateStr);
  }

  const sep = `  ${gray}·${reset}  `;
  process.stdout.write(parts.length ? parts.join(sep) : `${gray}Claude Code${reset}`);
});
