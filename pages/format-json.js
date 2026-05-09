// HTMX JSON 自动美化 — 拦截 raw JSON 响应，渲染为 HTML 表格/卡片
document.addEventListener('htmx:beforeSwap', function(evt) {
  const target = evt.detail.target;
  const raw = evt.detail.xhr.responseText;
  if (!raw || raw[0] !== '{' && raw[0] !== '[') return;

  try {
    const data = JSON.parse(raw);
    const formatted = renderAuto(target, data);
    if (formatted) {
      evt.detail.serverResponse = formatted;
      evt.detail.shouldSwap = true;
    }
  } catch(e) { /* not JSON, let HTMX handle */ }
});

function renderAuto(el, data) {
  if (Array.isArray(data) && data.length > 0 && typeof data[0] === 'object') {
    return renderTable(data);
  }
  if (Array.isArray(data) && data.length > 0 && typeof data[0] === 'string') {
    return renderList(data);
  }
  if (typeof data === 'object' && data !== null && !Array.isArray(data)) {
    return renderKV(data);
  }
  return null;
}

function renderTable(rows, maxRows) {
  maxRows = maxRows || 50;
  const keys = Object.keys(rows[0]).filter(k => k !== 'id' && k !== 'created_at');
  var h = '<div class="overflow-x-auto"><table class="w-full text-sm"><thead><tr class="border-b border-gray-700">';
  for (var i = 0; i < keys.length; i++) {
    h += '<th class="text-left text-gray-400 font-medium px-2 py-1 text-xs">' + escapeHtml(keys[i]) + '</th>';
  }
  h += '</tr></thead><tbody>';
  const limit = Math.min(rows.length, maxRows);
  for (var r = 0; r < limit; r++) {
    h += '<tr class="border-b border-gray-800 hover:bg-gray-800/50">';
    for (var j = 0; j < keys.length; j++) {
      var v = rows[r][keys[j]];
      h += '<td class="px-2 py-1 font-mono text-xs text-gray-300">' + formatVal(v) + '</td>';
    }
    h += '</tr>';
  }
  h += '</tbody></table>';
  if (rows.length > maxRows) h += '<div class="text-xs text-gray-500 mt-1 px-2">... 还有 ' + (rows.length - maxRows).toLocaleString() + ' 行</div>';
  h += '</div>';
  return h;
}

function renderList(items) {
  var h = '<ul class="space-y-1">';
  for (var i = 0; i < items.length; i++) {
    h += '<li class="text-sm text-gray-300 font-mono">' + escapeHtml(String(items[i])) + '</li>';
  }
  h += '</ul>';
  return h;
}

function renderKV(obj) {
  var keys = Object.keys(obj);
  var h = '<div class="space-y-2">';
  for (var i = 0; i < keys.length; i++) {
    var v = obj[keys[i]];
    h += '<div class="flex justify-between text-sm">';
    h += '<span class="text-gray-400">' + escapeHtml(keys[i]) + '</span>';
    h += '<span class="font-mono text-gray-200">' + formatVal(v) + '</span>';
    h += '</div>';
  }
  h += '</div>';
  return h;
}

function formatVal(v) {
  if (v === null || v === undefined) return '<span class="text-gray-600">null</span>';
  if (typeof v === 'boolean') return v ? '✓' : '✗';
  if (typeof v === 'number') return v.toLocaleString();
  var s = String(v);
  // 0x 地址
  if (s.startsWith('0x') && s.length === 42) {
    return '<span title="' + escapeHtml(s) + '" class="text-blue-400">' + escapeHtml(s.slice(0,6) + '...' + s.slice(-4)) + '</span>';
  }
  // 0x tx hash
  if (s.startsWith('0x') && s.length === 66) {
    return '<span title="' + escapeHtml(s) + '" class="text-purple-400">' + escapeHtml(s.slice(0,10) + '...') + '</span>';
  }
  // 0x value (uint256)
  if (s.startsWith('0x') && s.length > 10) {
    return '<span class="text-emerald-400">' + escapeHtml(s.slice(0,18) + '...') + '</span>';
  }
  return '<span class="text-gray-300">' + escapeHtml(s) + '</span>';
}

function escapeHtml(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
