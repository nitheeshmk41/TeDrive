// The web page other devices open for Wi-Fi transfer. It is one file with
// no outside resources, because the other device may have no internet.

const String wifiTransferPageHtml = r'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>TeDrive Wi-Fi transfer</title>
<style>
  :root { --bg:#f4f6fb; --card:#fff; --text:#101828; --muted:#667085; --line:#e4e7ec;
          --brand:#1677f0; --brand-soft:#e8f1fe; --ok:#12b76a; --bad:#d92d20; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#0b1220; --card:#141c2e; --text:#f2f4f7; --muted:#98a2b3; --line:#243049;
            --brand:#4c9aff; --brand-soft:#16284a; }
  }
  * { box-sizing:border-box; }
  body { margin:0; font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
         background:var(--bg); color:var(--text); }
  header { display:flex; align-items:center; gap:12px; padding:16px 20px; background:var(--card);
           border-bottom:1px solid var(--line); position:sticky; top:0; z-index:5; }
  .logo { width:40px; height:40px; border-radius:12px; background:var(--brand); color:#fff;
          display:grid; place-items:center; font-weight:700; }
  header h1 { font-size:17px; margin:0; }
  header p { margin:2px 0 0; font-size:13px; color:var(--muted); }
  .dot { width:9px; height:9px; border-radius:50%; background:var(--ok); margin-left:auto; flex:none; }
  .dot.off { background:var(--bad); }
  main { max-width:1040px; margin:0 auto; padding:16px; }
  .tabs { display:flex; gap:8px; margin-bottom:16px; }
  .tab { flex:1; padding:12px; border-radius:12px; border:1px solid var(--line); background:var(--card);
         color:var(--text); font:inherit; font-weight:600; cursor:pointer; }
  .tab.on { background:var(--brand); border-color:var(--brand); color:#fff; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:16px; padding:16px; }
  .bar { display:flex; gap:8px; flex-wrap:wrap; align-items:center; margin-bottom:12px; }
  input[type=search], input[type=text] { flex:1; min-width:160px; padding:10px 12px; border-radius:10px;
         border:1px solid var(--line); background:var(--bg); color:var(--text); font:inherit; }
  button.btn, a.btn { padding:10px 14px; border-radius:10px; border:0; background:var(--brand); color:#fff;
         font:inherit; font-weight:600; cursor:pointer; text-decoration:none; display:inline-block; }
  button.ghost { background:var(--brand-soft); color:var(--brand); }
  button:disabled { opacity:.45; cursor:default; }
  .grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(150px,1fr)); gap:12px; }
  @media (max-width:520px) { .grid { grid-template-columns:repeat(2,1fr); } main { padding:12px; } .card { padding:12px; } }
  .item { border:1px solid var(--line); border-radius:14px; overflow:hidden; background:var(--bg);
          position:relative; display:flex; flex-direction:column; }
  .item.sel { outline:3px solid var(--brand); }
  .thumb { aspect-ratio:1; background:var(--brand-soft); display:grid; place-items:center;
           color:var(--brand); font-weight:700; font-size:20px; cursor:pointer; overflow:hidden; }
  .thumb img { width:100%; height:100%; object-fit:cover; display:block; }
  .meta { padding:8px 10px; font-size:13px; }
  .meta b { display:block; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-weight:600; }
  .meta span { color:var(--muted); font-size:12px; }
  .item a.dl { position:absolute; right:8px; bottom:52px; width:34px; height:34px; border-radius:50%;
               background:var(--brand); color:#fff; display:grid; place-items:center; text-decoration:none;
               font-size:18px; box-shadow:0 2px 6px rgba(0,0,0,.3); }
  .check { position:absolute; left:8px; top:8px; width:22px; height:22px; accent-color:var(--brand); }
  .drop { border:2px dashed var(--line); border-radius:16px; padding:36px 16px; text-align:center;
          cursor:pointer; transition:.15s; }
  .drop.over { border-color:var(--brand); background:var(--brand-soft); }
  .drop strong { display:block; font-size:17px; margin-bottom:6px; }
  .drop span, .empty { color:var(--muted); font-size:14px; }
  .row { display:flex; align-items:center; gap:12px; padding:10px 0; border-bottom:1px solid var(--line); }
  .row:last-child { border-bottom:0; }
  .row .name { flex:1; min-width:0; }
  .row b { display:block; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:14px; }
  .row small { color:var(--muted); }
  progress { width:100%; height:6px; border-radius:3px; accent-color:var(--brand); }
  .state { font-size:13px; font-weight:600; white-space:nowrap; }
  .state.ok { color:var(--ok); } .state.bad { color:var(--bad); }
  #gate { max-width:360px; margin:12vh auto; text-align:center; }
  #gate input { text-align:center; font-size:26px; letter-spacing:8px; width:100%; margin:16px 0; }
  .hidden { display:none !important; }
  #viewer { position:fixed; inset:0; background:rgba(0,0,0,.92); z-index:20; display:grid; place-items:center; }
  #viewer img, #viewer video { max-width:96vw; max-height:88vh; }
  #viewer button { position:absolute; top:14px; right:14px; }
</style>
</head>
<body>
<div id="gate" class="card hidden">
  <div class="logo" style="margin:0 auto 12px">T</div>
  <h2 style="margin:0">Enter the access code</h2>
  <p class="empty">It is shown in TeDrive on the other device.</p>
  <form id="gateForm">
    <input type="text" id="codeInput" inputmode="numeric" maxlength="6" autocomplete="off" placeholder="000000">
    <button class="btn" style="width:100%">Connect</button>
  </form>
  <p id="gateErr" class="state bad"></p>
</div>

<div id="app" class="hidden">
  <header>
    <div class="logo">T</div>
    <div><h1 id="device">TeDrive</h1><p id="status">Connected over Wi-Fi. No internet data is used.</p></div>
    <div class="dot" id="dot" title="Connection"></div>
  </header>
  <main>
    <div class="tabs">
      <button class="tab on" id="tabGet">Get files</button>
      <button class="tab" id="tabSend">Send files</button>
    </div>

    <section id="get" class="card">
      <div class="bar">
        <input type="search" id="search" placeholder="Search files">
        <button class="btn ghost" id="selAll">Select all</button>
        <button class="btn" id="dlSel" disabled>Download selected</button>
      </div>
      <div class="grid" id="grid"></div>
      <p class="empty hidden" id="none">No files are available on the other device yet. In TeDrive, files marked offline appear here.</p>
    </section>

    <section id="send" class="card hidden">
      <div class="drop" id="drop">
        <strong>Drop files here, or tap to choose</strong>
        <span>They are sent straight to the other device.</span>
        <input type="file" id="pick" multiple class="hidden">
      </div>
      <div id="queue" style="margin-top:12px"></div>
    </section>
  </main>
</div>

<div id="viewer" class="hidden"><button class="btn">Close</button><div id="viewBox"></div></div>

<script>
(function () {
  var key = new URLSearchParams(location.search).get('k') || '';
  var files = [], selected = new Set(), $ = function (id) { return document.getElementById(id); };

  function api(path) { return path + (path.indexOf('?') < 0 ? '?' : '&') + 'k=' + encodeURIComponent(key); }
  function size(n) {
    if (n < 1024) return n + ' B';
    var u = ['KB', 'MB', 'GB'], i = -1;
    do { n /= 1024; i++; } while (n >= 1024 && i < 2);
    return n.toFixed(n < 10 ? 1 : 0) + ' ' + u[i];
  }
  function ext(name) { var i = name.lastIndexOf('.'); return i < 0 ? 'FILE' : name.slice(i + 1).toUpperCase().slice(0, 4); }
  function kind(name) {
    var e = ext(name).toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'webp'].indexOf(e) >= 0) return 'image';
    if (['mp4', 'webm', 'm4v'].indexOf(e) >= 0) return 'video';
    return '';
  }

  function showGate(message) {
    $('app').classList.add('hidden'); $('gate').classList.remove('hidden');
    $('gateErr').textContent = message || '';
  }
  $('gateForm').onsubmit = function (e) {
    e.preventDefault();
    key = $('codeInput').value.trim();
    history.replaceState(null, '', '/?k=' + encodeURIComponent(key));
    load();
  };

  function load() {
    fetch(api('/api/info')).then(function (r) {
      if (r.status === 403) { showGate(key ? 'That code is not right.' : ''); return null; }
      return r.json();
    }).then(function (info) {
      if (!info) return;
      $('gate').classList.add('hidden'); $('app').classList.remove('hidden');
      $('device').textContent = info.device;
      document.title = info.device + ' · TeDrive';
      files = info.files; render();
    }).catch(function () { showGate('Cannot reach the other device. Is Wi-Fi transfer still open?'); });
  }

  function render() {
    var q = $('search').value.trim().toLowerCase(), grid = $('grid');
    grid.textContent = '';
    var shown = files.filter(function (f) { return !q || f.name.toLowerCase().indexOf(q) >= 0; });
    $('none').classList.toggle('hidden', files.length > 0);
    shown.forEach(function (f) {
      var item = document.createElement('div');
      item.className = 'item' + (selected.has(f.id) ? ' sel' : '');
      var thumb = document.createElement('div'); thumb.className = 'thumb';
      if (f.thumb) {
        var img = document.createElement('img'); img.loading = 'lazy'; img.alt = '';
        img.src = api('/thumb?id=' + f.id); thumb.appendChild(img);
      } else { thumb.textContent = ext(f.name); }
      thumb.onclick = function () { preview(f); };
      var box = document.createElement('input'); box.type = 'checkbox'; box.className = 'check';
      box.checked = selected.has(f.id);
      box.onchange = function () {
        if (box.checked) selected.add(f.id); else selected.delete(f.id);
        item.classList.toggle('sel', box.checked); updateBar();
      };
      var dl = document.createElement('a'); dl.className = 'dl'; dl.textContent = '↓';
      dl.title = 'Download'; dl.href = api('/file?id=' + f.id); dl.setAttribute('download', f.name);
      var meta = document.createElement('div'); meta.className = 'meta';
      var b = document.createElement('b'); b.textContent = f.name; b.title = f.name;
      var s = document.createElement('span'); s.textContent = size(f.size);
      meta.appendChild(b); meta.appendChild(s);
      item.appendChild(thumb); item.appendChild(box); item.appendChild(dl); item.appendChild(meta);
      grid.appendChild(item);
    });
    updateBar();
  }
  function updateBar() {
    $('dlSel').disabled = selected.size === 0;
    $('dlSel').textContent = selected.size ? 'Download ' + selected.size + ' selected' : 'Download selected';
    $('selAll').textContent = selected.size === files.length && files.length ? 'Clear' : 'Select all';
  }
  $('search').oninput = render;
  $('selAll').onclick = function () {
    if (selected.size === files.length) selected.clear();
    else files.forEach(function (f) { selected.add(f.id); });
    render();
  };
  $('dlSel').onclick = function () {
    var ids = Array.from(selected);
    location.href = ids.length === 1 ? api('/file?id=' + ids[0]) : api('/zip?ids=' + ids.join(','));
  };

  function preview(f) {
    var k = kind(f.name);
    if (!k) { location.href = api('/file?id=' + f.id); return; }
    var el = document.createElement(k === 'image' ? 'img' : 'video');
    el.src = api('/file?id=' + f.id + '&view=1');
    if (k === 'video') { el.controls = true; el.autoplay = true; }
    $('viewBox').textContent = ''; $('viewBox').appendChild(el);
    $('viewer').classList.remove('hidden');
  }
  $('viewer').onclick = function (e) {
    if (e.target.tagName === 'IMG' || e.target.tagName === 'VIDEO') return;
    $('viewBox').textContent = ''; $('viewer').classList.add('hidden');
  };

  function tab(get) {
    $('get').classList.toggle('hidden', !get); $('send').classList.toggle('hidden', get);
    $('tabGet').classList.toggle('on', get); $('tabSend').classList.toggle('on', !get);
    if (get) load();
  }
  $('tabGet').onclick = function () { tab(true); };
  $('tabSend').onclick = function () { tab(false); };

  // Sending: one file at a time, each with its own progress bar.
  var queue = [], busy = false;
  function add(list) {
    Array.prototype.forEach.call(list, function (file) {
      var row = document.createElement('div'); row.className = 'row';
      var name = document.createElement('div'); name.className = 'name';
      var b = document.createElement('b'); b.textContent = file.name;
      var bar = document.createElement('progress'); bar.max = 1; bar.value = 0;
      var small = document.createElement('small'); small.textContent = size(file.size);
      name.appendChild(b); name.appendChild(bar); name.appendChild(small);
      var state = document.createElement('div'); state.className = 'state'; state.textContent = 'Waiting';
      row.appendChild(name); row.appendChild(state);
      $('queue').prepend(row);
      queue.push({ file: file, bar: bar, state: state, small: small });
    });
    next();
  }
  function next() {
    if (busy || !queue.length) return;
    busy = true;
    var job = queue.shift(), xhr = new XMLHttpRequest(), started = Date.now();
    xhr.open('POST', api('/upload?name=' + encodeURIComponent(job.file.name)));
    xhr.upload.onprogress = function (e) {
      if (!e.lengthComputable) return;
      job.bar.value = e.loaded / e.total;
      var speed = e.loaded / Math.max(1, (Date.now() - started) / 1000);
      job.small.textContent = size(e.loaded) + ' of ' + size(e.total) + ' · ' + size(speed) + '/s';
      job.state.textContent = Math.round(100 * e.loaded / e.total) + '%';
    };
    xhr.onload = function () {
      var ok = xhr.status === 200;
      job.bar.value = ok ? 1 : job.bar.value;
      job.state.textContent = ok ? 'Sent' : 'Failed';
      job.state.className = 'state ' + (ok ? 'ok' : 'bad');
      busy = false; next();
    };
    xhr.onerror = function () {
      job.state.textContent = 'Failed'; job.state.className = 'state bad';
      busy = false; next();
    };
    job.state.textContent = '0%';
    xhr.send(job.file);
  }
  var drop = $('drop');
  drop.onclick = function () { $('pick').click(); };
  $('pick').onchange = function () { add(this.files); this.value = ''; };
  ['dragenter', 'dragover'].forEach(function (n) {
    document.addEventListener(n, function (e) { e.preventDefault(); tab(false); drop.classList.add('over'); });
  });
  ['dragleave', 'drop'].forEach(function (n) {
    document.addEventListener(n, function (e) { e.preventDefault(); drop.classList.remove('over'); });
  });
  document.addEventListener('drop', function (e) { if (e.dataTransfer) add(e.dataTransfer.files); });

  // Shows at once when the other device closes Wi-Fi transfer.
  setInterval(function () {
    if ($('app').classList.contains('hidden')) return;
    fetch(api('/api/ping')).then(function (r) { return r.ok; }, function () { return false; }).then(function (ok) {
      $('dot').classList.toggle('off', !ok);
      $('status').textContent = ok ? 'Connected over Wi-Fi. No internet data is used.'
                                   : 'Connection lost. Open Wi-Fi transfer in TeDrive again.';
    });
  }, 3000);

  if (key) load(); else showGate('');
})();
</script>
</body>
</html>
''';
