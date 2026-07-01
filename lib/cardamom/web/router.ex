defmodule Cardamom.Web.Router do
  @moduledoc """
  Hand-coded HTTP routes (no framework). The model: match method+path, return a
  hand-coded HTML page; data URLs return JSON. JS in the page polls the JSON.
  """

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, page())
  end

  get "/stats.json" do
    json(conn, Cardamom.Stats.snapshot())
  end

  get "/peers.json" do
    json(conn, %{peers: Cardamom.Peers.list()})
  end

  get "/system.json" do
    json(conn, Cardamom.Introspect.system())
  end

  get "/processes.json" do
    json(conn, %{processes: Cardamom.Introspect.processes(25)})
  end

  get "/tree.json" do
    json(conn, Cardamom.Introspect.tree())
  end

  get "/forest.json" do
    json(conn, forest_view())
  end

  get "/chaindata.json" do
    json(conn, chaindata_view())
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp json(conn, data) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(data))
  end

  # Forest view for the UI. Hashes are raw binaries (not JSON-safe), so encode each
  # to short hex here. Returns an empty view if the forest server isn't running.
  defp forest_view do
    if Process.whereis(Cardamom.Forest.Server) do
      v = Cardamom.Forest.Server.view(Cardamom.Forest.Server, 14)

      %{
        tip: short(v.tip),
        tip_height: v.tip_height,
        node_count: v.node_count,
        forks: v.forks,
        floating: v.floating,
        rows:
          Enum.map(v.rows, fn r ->
            %{height: r.height, hash: short(r.hash), fork?: r.fork?}
          end)
      }
    else
      %{tip: nil, tip_height: nil, node_count: 0, forks: 0, floating: 0, rows: []}
    end
  end

  defp short(h) when is_binary(h), do: Base.encode16(h, case: :lower) |> String.slice(0, 12)
  defp short(h), do: inspect(h)

  # Chain-data view: the body-backfill progress (headers vs bodies gap) + UTXO-set totals +
  # the recent tx-bearing blocks. Empty view if the store isn't up (e.g. early boot).
  defp chaindata_view do
    if Process.whereis(Cardamom.ChainStore) do
      Map.put(Cardamom.ChainStore.chain_summary(), :recent_txs, Cardamom.ChainStore.recent_tx_blocks(10))
    else
      %{headers: 0, bodies: 0, gap: 0, pending: 0, txos: 0, unspent: 0, spent: 0, recent_txs: []}
    end
  rescue
    _ -> %{headers: 0, bodies: 0, gap: 0, pending: 0, txos: 0, unspent: 0, spent: 0, recent_txs: []}
  end

  defp page do
    """
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <title>Cardamom</title>
      <style>
        body { font: 14px/1.5 ui-monospace, monospace; margin: 2rem; background:#111; color:#ddd; }
        h1 { color:#8fd; } .stat { display:inline-block; margin-right:2rem; }
        .num { color:#8fd; font-weight:bold; } #log { margin-top:1rem; }
        .row { border-bottom:1px solid #333; padding:2px 0; }
        .ev { color:#fc8; } .meta { color:#888; }
        h2 { color:#8fd; font-size:1rem; margin:1.5rem 0 .3rem; }
        pre { background:#1a1a1a; padding:.5rem; border:1px solid #333; overflow:auto; }
        table { border-collapse:collapse; width:100%; }
        th, td { text-align:left; padding:2px 8px; border-bottom:1px solid #2a2a2a; }
        th { color:#8fd; }
        .cols { display:flex; gap:2rem; align-items:flex-start; flex-wrap:wrap; }
        /* LEFT main column gets the flexible space; RIGHT side is a fixed sidebar
           stacking the supervision tree (fixed) over the forest (grows downward). */
        .main { flex:1 1 0; min-width:360px; }
        .side { flex:0 0 380px; min-width:360px; }
        .side pre { max-height:none; }
        #forest { max-height:70vh; overflow:auto; }
        .bar { background:#222; border:1px solid #333; height:10px; margin:.3rem 0 .8rem; border-radius:3px; overflow:hidden; }
        .bar-fill { background:#8fd; height:100%; width:0%; transition:width .5s; }
        /* Connection status: green = live, red = the node poll failed (stale values). */
        .conn { font-size:0.9rem; padding:2px 8px; border-radius:4px; vertical-align:middle; }
        .conn.live { background:#173; color:#8fd; }
        .conn.dead { background:#711; color:#fbb; }
        body.stale .num { opacity:0.4; }  /* grey the numbers so stale can't look live */
      </style>
    </head>
    <body>
      <h1>Cardamom <span id="conn" class="conn">connecting…</span></h1>
      <div>
        <span class="stat">uptime <span class="num" id="uptime">-</span>s</span>
        <span class="stat">peers <span class="num" id="peercount">-</span></span>
        <span class="stat">protocol events <span class="num" id="events">-</span></span>
      </div>

      <div class="cols">
        <!-- LEFT: the wide / log-heavy stuff, gets the flexible space -->
        <div class="main">
          <h2>Chain data <span class="meta" id="backfill-summary"></span></h2>
          <div id="chaindata"></div>
          <div class="bar"><div class="bar-fill" id="backfill-bar"></div></div>
          <table id="recenttxs"><thead><tr>
            <th>block</th><th>slot</th><th>txs</th>
          </tr></thead><tbody></tbody></table>

          <h2>Network topology — open connections</h2>
          <table id="peers"><thead><tr>
            <th>address</th><th>dir</th><th>ver</th><th>name</th><th>protocols (activity)</th>
          </tr></thead><tbody></tbody></table>

          <h2>VM</h2>
          <div id="system"></div>

          <h2>Processes (top 25 by mailbox)</h2>
          <table id="procs"><thead><tr>
            <th>name / pid</th><th>mailbox</th><th>mem (KB)</th><th>reds</th><th>current fn</th>
          </tr></thead><tbody></tbody></table>

          <h2>Event log</h2>
          <div id="log"></div>
        </div>

        <!-- RIGHT: supervision tree (fixed-size) on top, forest (grows) below -->
        <div class="side">
          <h2>Supervision tree</h2>
          <pre id="tree"></pre>
          <h2>Forest <span class="meta" id="forest-summary"></span></h2>
          <pre id="forest"></pre>
        </div>
      </div>

      <script>
        function esc(s) { return String(s).replace(/[&<>]/g, function(c){
          return {'&':'&amp;','<':'&lt;','>':'&gt;'}[c]; }); }

        function renderTree(node, depth) {
          const pad = '  '.repeat(depth);
          const tag = node.type === 'supervisor' ? '[S]' : '[w]';
          let out = pad + tag + ' ' + esc(node.name) + '\\n';
          (node.children || []).forEach(function(c){ out += renderTree(c, depth+1); });
          return out;
        }

        // Rows are newest-first (tip at top). Spine nodes draw as 'o h hash' joined by
        // '|'; fork rows (fork?: true) hang off the spine with a '\\' branch marker.
        function renderForest(rows) {
          if (!rows || !rows.length) return '(empty)';
          let out = '';
          rows.forEach(function(r, i) {
            const h = (r.height == null ? '\\u2205' : r.height);   // ∅ = floating (no height)
            if (r["fork?"]) {
              out += '  | \\\\\\n';
              out += '  |  o ' + h + ' ' + esc(r.hash) + ' (fork)\\n';
            } else {
              out += 'o ' + h + ' ' + esc(r.hash) + '\\n';
              if (i < rows.length - 1) out += '|\\n';
            }
          });
          return out;
        }

        // Reflect whether the last poll reached the node. On failure we mark the page STALE so
        // frozen numbers can't masquerade as live (the 6-day-uptime confusion — it was a dead
        // tab showing its last value). Uptime is the node's OWN wall_clock, polled like any other
        // datum, so a live tab always shows the real node age and a dead one says so.
        function setConn(live) {
          const c = document.getElementById('conn');
          c.textContent = live ? 'live' : 'disconnected — stale';
          c.className = 'conn ' + (live ? 'live' : 'dead');
          document.body.classList.toggle('stale', !live);
        }

        async function tick() {
          try {
            const s = await (await fetch('/stats.json')).json();
            document.getElementById('uptime').textContent = s.uptime_seconds;
            document.getElementById('peercount').textContent = s.peers_connected;
            document.getElementById('events').textContent = s.protocol_events;
            document.getElementById('log').innerHTML = s.recent.map(function(l) {
              const t = new Date(l.at).toLocaleTimeString();
              return '<div class="row"><span class="meta">' + t + '</span> ' +
                     '<span class="ev">' + esc(l.event) + '</span> ' +
                     '<span class="meta">' + esc(JSON.stringify(l.metadata)) + '</span></div>';
            }).join('');

            const peers = (await (await fetch('/peers.json')).json()).peers;
            document.querySelector('#peers tbody').innerHTML = peers.map(function(p){
              const protos = Object.keys(p.protocols || {}).map(function(k){
                const a = p.protocols[k];
                return k + ' (' + a.count + ', ' + (a.last_msg || '') + ')';
              }).join(', ');
              return '<tr><td>' + esc(p.address) + '</td><td>' + esc(p.direction) +
                     '</td><td>' + (p.version == null ? '?' : p.version) +
                     '</td><td class="meta">' + esc(p.name || '\\u2014') +
                     '</td><td>' + esc(protos) + '</td></tr>';
            }).join('') || '<tr><td colspan="5" class="meta">no open connections</td></tr>';

            const sys = await (await fetch('/system.json')).json();
            document.getElementById('system').innerHTML =
              '<span class="stat">procs <span class="num">' + sys.process_count + '</span></span>' +
              '<span class="stat">mem <span class="num">' + Math.round(sys.memory_total_bytes/1048576) + '</span> MB</span>' +
              '<span class="stat">ETS <span class="num">' + Math.round(sys.memory_ets_bytes/1048576) + '</span> MB</span>' +
              '<span class="stat">run queue <span class="num">' + sys.run_queue + '</span></span>' +
              '<span class="stat">schedulers <span class="num">' + sys.schedulers + '</span></span>';

            const tree = await (await fetch('/tree.json')).json();
            document.getElementById('tree').textContent = renderTree(tree, 0);

            const fv = await (await fetch('/forest.json')).json();
            document.getElementById('forest-summary').textContent =
              fv.tip
                ? 'tip ' + fv.tip + '\\u2026 h=' + (fv.tip_height == null ? '?' : fv.tip_height) +
                  '  nodes ' + fv.node_count + '  forks ' + fv.forks + '  floating ' + fv.floating
                : '(empty)';
            document.getElementById('forest').textContent = renderForest(fv.rows);

            const cd = await (await fetch('/chaindata.json')).json();
            const pct = cd.headers > 0 ? Math.floor(100 * cd.bodies / cd.headers) : 0;
            document.getElementById('backfill-summary').textContent =
              'bodies ' + cd.bodies + ' / headers ' + cd.headers +
              (cd.gap > 0 ? '  (' + cd.gap + ' behind)' : '  (caught up)');
            document.getElementById('backfill-bar').style.width = pct + '%';
            document.getElementById('chaindata').innerHTML =
              '<span class="stat">bodies <span class="num">' + cd.bodies + '</span></span>' +
              '<span class="stat">gap <span class="num">' + cd.gap + '</span></span>' +
              '<span class="stat">pending <span class="num">' + cd.pending + '</span></span>' +
              '<span class="stat">UTXOs <span class="num">' + cd.txos + '</span></span>' +
              '<span class="stat">unspent <span class="num">' + cd.unspent + '</span></span>' +
              '<span class="stat">spent <span class="num">' + cd.spent + '</span></span>';
            document.querySelector('#recenttxs tbody').innerHTML = (cd.recent_txs || []).map(function(t){
              return '<tr><td>' + t.block_no + '</td><td class="meta">' + t.slot +
                     '</td><td>' + t.tx_count + '</td></tr>';
            }).join('') || '<tr><td colspan="3" class="meta">no transactions seen yet</td></tr>';

            const procs = (await (await fetch('/processes.json')).json()).processes;
            document.querySelector('#procs tbody').innerHTML = procs.map(function(p){
              return '<tr><td>' + esc(p.name || p.pid) + '</td><td>' + p.message_queue_len +
                     '</td><td>' + Math.round(p.memory_bytes/1024) + '</td><td>' + p.reductions +
                     '</td><td class="meta">' + esc(p.current_function || '') + '</td></tr>';
            }).join('');
            setConn(true);
          } catch (e) {
            // A failed poll = the node is unreachable (stopped, or this tab outlived it).
            setConn(false);
          }
        }
        setInterval(tick, 1000); tick();
      </script>
    </body>
    </html>
    """
  end
end
