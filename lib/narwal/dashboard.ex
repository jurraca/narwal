defmodule Narwal.Dashboard do
  @moduledoc """
  HTML rendering for the Narwal dashboard.

  Reads ETS tables directly — no GenServer calls.
  Two render functions:
    - render_page/0 — full HTML document (shell + HTMX + initial content)
    - render_fragment/0 — just the status <div> (polled by HTMX every 2s)
  """

  alias Narwal.{Stats, TreeCache}

  @htmx_cdn "https://unpkg.com/htmx.org@1.9.12"

  @css """
  :root {
    --bg: #1a1b26;
    --fg: #c0caf5;
    --accent: #7aa2f7;
    --dim: #7dcfff;
    --green: #9ece6a;
    --red: #f7768e;
    --border: #2a2e3f;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    background: var(--bg);
    color: var(--fg);
    font-family: 'SF Mono', 'Cascadia Code', 'Fira Code', 'Consolas', monospace;
    font-size: 13px;
    padding: 24px;
    max-width: 1100px;
    margin: 0 auto;
  }
  h1 { color: var(--accent); font-size: 18px; margin-bottom: 4px; }
  .subtitle { color: var(--dim); font-size: 12px; margin-bottom: 24px; }
  h2 {
    color: var(--dim);
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 1px;
    margin: 20px 0 8px 0;
    padding-bottom: 4px;
    border-bottom: 1px solid var(--border);
  }
  table { width: 100%; border-collapse: collapse; }
  td { padding: 2px 8px 2px 0; vertical-align: top; }
  td:first-child { color: var(--dim); white-space: nowrap; width: 120px; }
  .hash { color: var(--accent); }
  .url { color: var(--fg); }
  .count { color: var(--green); }
  .warn { color: var(--red); }
  .dim { color: var(--dim); }
  .stat-grid { display: flex; gap: 24px; flex-wrap: wrap; }
  .stat-box { }
  .stat-box .label { color: var(--dim); font-size: 11px; }
  .stat-box .value { color: var(--green); font-size: 20px; }
  .columns { display: flex; gap: 32px; align-items: flex-start; }
  .col-data { flex: 1 1 50%; min-width: 0; }
  .col-graph { flex: 1 1 50%; }
  .graph { margin: 0; }
  .graph svg { display: block; }
  .graph text { font-family: 'SF Mono', 'Cascadia Code', 'Fira Code', 'Consolas', monospace; }
  .graph .layer-label { fill: #7dcfff; font-size: 11px; text-transform: uppercase; letter-spacing: 1px; }
  .graph .node-count { fill: #1a1b26; font-size: 11px; font-weight: bold; text-anchor: middle; dominant-baseline: central; }
  .graph .node-sublabel { fill: #7dcfff; font-size: 10px; text-anchor: middle; }
  .graph .connector { stroke: #2a2e3f; stroke-width: 1.5; fill: none; }
  .graph .dim-node { opacity: 0.25; }
  .root-section { margin-bottom: 20px; border: 1px solid var(--border); padding: 12px; border-radius: 4px; }
  .root-header { margin-bottom: 8px; }
  .root-npub { color: var(--accent); font-weight: bold; font-size: 12px; word-break: break-all; }
  .root-pubkey { color: var(--dim); font-size: 11px; }
  .root-hash { color: var(--dim); font-size: 11px; }
  .root-meta { display: flex; gap: 16px; margin: 8px 0; color: var(--green); font-size: 12px; }
  .link-table { width: 100%; margin-top: 8px; font-size: 12px; }
  .link-table th { text-align: left; color: var(--dim); padding: 4px 8px 4px 0; border-bottom: 1px solid var(--border); font-size: 11px; text-transform: uppercase; letter-spacing: 0.5px; }
  .link-table td { padding: 2px 8px 2px 0; vertical-align: top; color: var(--fg); }
  .link-table td:first-child { color: var(--accent); white-space: nowrap; }
  .roots-empty { color: var(--dim); font-style: italic; }
  .root-manifest-missing { color: var(--red); font-size: 12px; margin-top: 8px; }
  .root-hash-full { color: var(--accent); font-family: 'SF Mono', 'Cascadia Code', 'Fira Code', 'Consolas', monospace; font-size: 11px; word-break: break-all; margin-top: 4px; }
  .root-hash-label { color: var(--dim); font-size: 10px; text-transform: uppercase; letter-spacing: 0.5px; }
  """

  def render_page do
    "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n" <>
      "<meta charset=\"utf-8\">\n" <>
      "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" <>
      "<title>Narwal — Nix Binary Cache Proxy</title>\n" <>
      "<script src=\"#{@htmx_cdn}\"></script>\n" <>
      "<style>\n#{@css}</style>\n" <>
      "</head>\n<body>\n" <>
      "<h1>Narwal</h1>\n" <>
      "<div class=\"subtitle\">Nix Binary Cache Proxy — Nostr + Blossom</div>\n" <>
      render_fragment() <>
      "<h2>Roots</h2>\n" <>
      "<div id=\"roots\" hx-get=\"/dashboard/roots\" hx-trigger=\"load\" hx-swap=\"innerHTML\"></div>\n" <>
      "\n</body>\n</html>"
  end

  def render_fragment do
    relays = Application.get_env(:narwal, :relays, [])
    roots = get_roots()
    blossom_servers = get_blossom_servers()
    cache_counts = get_cache_counts()
    narinfo_index_size = get_narinfo_index_size()
    stats = Stats.get_all()

    graph_data = %{
      blossom_servers: blossom_servers,
      relays: relays,
      cache: cache_counts,
      stats: stats
    }

    """
    <div hx-get="/dashboard/content" hx-trigger="every 2s" hx-swap="outerHTML">
      <div class="columns">
        <div class="col-data">
          <h2>Blossom Servers (#{length(blossom_servers)})</h2>
    #{render_list(blossom_servers)}

          <h2>Caches (#{length(roots)})</h2>
    #{render_publishers(roots)}

          <h2>Relays</h2>
    #{render_list(relays)}

          <h2>Cache</h2>
          <table>
            <tr><td>Tree nodes</td><td class="count">#{cache_counts.nodes}</td></tr>
            <tr><td>Narinfo blobs</td><td class="count">#{cache_counts.narinfos}</td></tr>
            <tr><td>Narinfo index</td><td class="count">#{narinfo_index_size}</td></tr>
          </table>

          <h2>Requests</h2>
          <div class="stat-grid">
            <div class="stat-box">
              <div class="label">Narinfo requests</div>
              <div class="value">#{stats[:narinfo_requests]}</div>
            </div>
            <div class="stat-box">
              <div class="label">Hits</div>
              <div class="value">#{stats[:narinfo_hits]}</div>
            </div>
            <div class="stat-box">
              <div class="label">Misses</div>
              <div class="value">#{stats[:narinfo_misses]}</div>
            </div>
            <div class="stat-box">
              <div class="label">404s</div>
              <div class="value warn">#{stats[:narinfo_404s]}</div>
            </div>
          </div>
          <div class="stat-grid" style="margin-top: 16px;">
            <div class="stat-box">
              <div class="label">NAR requests</div>
              <div class="value">#{stats[:nar_requests]}</div>
            </div>
            <div class="stat-box">
              <div class="label">NAR 404s</div>
              <div class="value warn">#{stats[:nar_404s]}</div>
            </div>
          </div>
        </div>
        <div class="col-graph">
    #{render_tree_graph(graph_data)}
        </div>
      </div>
    </div>
    """
  end

  # ── Tree Graph ──────────────────────────────────────────

  @svg_w 760
  @svg_cx 380
  @svg_r 20
  @svg_ys [50, 170, 290, 410]
  @svg_h 480
  @max_nodes 8

  defp render_tree_graph(data) do
    %{
      blossom_servers: blossom_servers,
      relays: relays,
      cache: cache,
      stats: stats
    } = data

    [y1, y2, y3, y4] = @svg_ys

    # Layer 1: Blossom servers
    blossom_items = Enum.take(blossom_servers, @max_nodes)
    blossom_xs = circle_positions(length(blossom_items))
    blossom_count = length(blossom_servers)

    # Layer 2: Relays
    relay_items = Enum.take(relays, @max_nodes)
    relay_xs = circle_positions(length(relay_items))
    relay_count = length(relays)

    # Layer 3: Cache (2 fixed circles)
    cache_nodes = [
      {"nodes", cache.nodes, "#a9b1d6"},
      {"narinfos", cache.narinfos, "#a9b1d6"}
    ]
    cache_xs = circle_positions(length(cache_nodes))

    # Layer 4: Requests
    request_items =
      [
        {"narinfo", stats[:narinfo_requests], "#9ece6a"},
        {"nar", stats[:nar_requests], "#7aa2f7"}
      ]
      |> Enum.concat(
        if stats[:narinfo_404s] + stats[:nar_404s] > 0 do
          [{"404", stats[:narinfo_404s] + stats[:nar_404s], "#f7768e"}]
        else
          []
        end
      )
    request_xs = circle_positions(length(request_items))

    connectors =
      render_connectors(y1, y2, blossom_xs, relay_xs) <>
        render_connectors(y2, y3, relay_xs, cache_xs) <>
        render_connectors(y3, y4, cache_xs, request_xs) <>
        render_bus(request_xs, y4)

    labels =
      render_layer_label(y1, "Blossom") <>
        render_layer_label(y2, "Relays") <>
        render_layer_label(y3, "Cache") <>
        render_layer_label(y4, "Requests")

    blossom_svg = render_nodes(blossom_items, blossom_xs, y1, "#7aa2f7", &short_host/1, blossom_count)
    relay_svg = render_nodes(relay_items, relay_xs, y2, "#9ece6a", &short_host/1, relay_count)
    cache_svg = render_count_nodes(cache_nodes, cache_xs, y3)
    request_svg = render_count_nodes(request_items, request_xs, y4)

    """
      <div class="graph">
        <svg width="#{@svg_w}" height="#{@svg_h}" xmlns="http://www.w3.org/2000/svg">
    #{connectors}
    #{labels}
    #{blossom_svg}
    #{relay_svg}
    #{cache_svg}
    #{request_svg}
        </svg>
      </div>
    """
  end

  defp circle_positions(0), do: [@svg_cx]
  defp circle_positions(1), do: [@svg_cx]

  defp circle_positions(n) do
    n = min(n, @max_nodes)
    spacing = min(110, div(600, n))
    start_x = @svg_cx - div((n - 1) * spacing, 2)
    Enum.map(0..(n - 1), fn i -> start_x + i * spacing end)
  end

  defp render_connectors(y_top, y_bot, top_xs, _bot_xs) do
    top_bus = render_bus(top_xs, y_top)
    vline = "<line x1=\"#{@svg_cx}\" y1=\"#{y_top + @svg_r}\" x2=\"#{@svg_cx}\" y2=\"#{y_bot - @svg_r}\" class=\"connector\" />"

    top_bus <> vline
  end

  defp render_bus(xs, y) when length(xs) > 1 do
    min_x = Enum.min(xs)
    max_x = Enum.max(xs)
    "<line x1=\"#{min_x}\" y1=\"#{y}\" x2=\"#{max_x}\" y2=\"#{y}\" class=\"connector\" />"
  end

  defp render_bus(_, _), do: ""

  defp render_layer_label(y, text) do
    "<text x=\"8\" y=\"#{y + 4}\" class=\"layer-label\">#{text}</text>\n"
  end

  defp render_nodes(items, xs, y, color, label_fn, total_count) do
    if items == [] do
      render_empty_node(@svg_cx, y, color)
    else
      items
      |> Enum.zip(xs)
      |> Enum.with_index()
      |> Enum.map(fn {{item, x}, idx} ->
        is_last = idx == length(items) - 1
        label = if is_last and total_count > @max_nodes, do: "+#{total_count - @max_nodes}", else: label_fn.(item)
        render_single_node(x, y, color, "1", label)
      end)
      |> Enum.join("\n")
    end
  end

  defp render_count_nodes(items, xs, y) do
    if items == [] do
      render_empty_node(@svg_cx, y, "#a9b1d6")
    else
      items
      |> Enum.zip(xs)
      |> Enum.map(fn {{label, count, color}, x} ->
        render_single_node(x, y, color, Integer.to_string(count), label)
      end)
      |> Enum.join("\n")
    end
  end

  defp render_single_node(x, y, color, count_str, label) do
    "<circle cx=\"#{x}\" cy=\"#{y}\" r=\"#{@svg_r}\" fill=\"#{color}\" />\n" <>
      "<text x=\"#{x}\" y=\"#{y}\" class=\"node-count\">#{count_str}</text>\n" <>
      "<text x=\"#{x}\" y=\"#{y + @svg_r + 14}\" class=\"node-sublabel\">#{escape(label)}</text>"
  end

  defp render_empty_node(x, y, color) do
    "<circle cx=\"#{x}\" cy=\"#{y}\" r=\"#{@svg_r}\" fill=\"#{color}\" class=\"dim-node\" />\n" <>
      "<text x=\"#{x}\" y=\"#{y + @svg_r + 14}\" class=\"node-sublabel\">—</text>"
  end

  defp short_host(url) do
    case URI.parse(url) do
      %URI{host: nil} -> String.slice(url, 0, 20)
      %URI{host: host} -> String.slice(host, 0, 24)
    end
  end

  # ── Info sections ───────────────────────────────────────

  defp render_list(items) do
    if items == [] do
      "      <span class=\"dim\">—</span>"
    else
      items
      |> Enum.map(fn item -> "      <div class=\"url\">#{escape(item)}</div>" end)
      |> Enum.join("\n")
    end
  end

  defp render_publishers(roots) do
    if roots == [] do
      "      <span class=\"dim\">No caches resolved</span>"
    else
      roots
      |> Enum.map(fn root ->
        "      <tr>\n" <>
          "        <td class=\"hash\">#{short_hex(root.pubkey)}</td>\n" <>
          "        <td>\n" <>
          "          root=<span class=\"hash\">#{short_hex(root.root_hash_hex)}</span>\n" <>
          "          channel=#{channel_label(root.channel)} " <>
          "          #{length(root.nix_sig_keys)} sig keys\n" <>
          "        </td>\n" <>
          "      </tr>"
      end)
      |> Enum.join("\n")
    end
  end

  defp channel_label(:default), do: "default"
  defp channel_label(channel), do: channel

  defp get_roots do
    case :ets.match(:narwal_roots, {{:root, :"$1", :"$2"}, :"$3"}) do
      [] -> []
      rows -> Enum.map(rows, fn [pubkey, channel, root] -> root |> Map.put(:pubkey, pubkey) |> Map.put(:channel, channel) end)
    end
  rescue
    ArgumentError -> []
  end

  defp get_blossom_servers do
    case :ets.lookup(:narwal_roots, :blossom_servers) do
      [{:blossom_servers, servers}] -> servers
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  defp get_cache_counts do
    nodes = safe_select_count(:narwal_tree_cache, {{:node, :_}, :_})
    narinfos = safe_select_count(:narwal_tree_cache, {{:narinfo, :_}, :_})
    %{nodes: nodes, narinfos: narinfos}
  end

  defp get_narinfo_index_size do
    safe_select_count(:narwal_roots, {{:narinfo, :_}, :_})
  end

  defp safe_select_count(table, pattern) do
    :ets.select_count(table, [{pattern, [], [true]}])
  rescue
    ArgumentError -> 0
  end

  defp short_hex(hex) when is_binary(hex) do
    if String.length(hex) > 12 do
      String.slice(hex, 0, 8) <> "…"
    else
      hex
    end
  end

  defp short_hex(_), do: "?"

  defp format_bytes(0), do: "0"

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_bytes(bytes) when bytes < 1024 * 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes) do
    "#{Float.round(bytes / (1024 * 1024), 1)} MB"
  end

  # ── Roots fragment ────────────────────────────────────────

  def render_roots do
    roots = get_roots()

    if roots == [] do
      "<div class=\"roots-empty\">No caches resolved</div>"
    else
      roots
      |> Enum.map(&render_root/1)
      |> Enum.join("\n")
    end
  end

  defp render_root(root) do
    npub = hex_to_npub(root.pubkey)

    manifest_html =
      case TreeCache.lookup_node(root.root_hash_hex) do
        {:ok, node} -> render_manifest(node)
        :miss -> "<div class=\"root-manifest-missing\">Manifest not cached</div>"
      end

    link_count = Map.get(root, :link_count, 0)
    total_bytes = Map.get(root, :total_bytes, 0)

    """
    <div class="root-section">
      <div class="root-header">
        <div class="root-npub">#{escape(npub)}</div>
        <div class="root-pubkey">#{short_hex(root.pubkey)} · #{channel_label(root.channel)}</div>
        <div class="root-hash-label">hashtree root</div>
        <div class="root-hash-full">#{root.root_hash_hex}</div>
      </div>
      <div class="root-meta">
        <span>#{link_count} links</span>
        <span>#{format_bytes(total_bytes)}</span>
      </div>
      #{manifest_html}
    </div>
    """
  end

  defp render_manifest(%{l: links}) when links == [] do
    "<div class=\"roots-empty\">Empty manifest</div>"
  end

  defp render_manifest(%{l: links}) do
    rows =
      Enum.map(links, fn link ->
        hash_hex = Base.encode16(link.h, case: :lower)
        name = link.n || "—"

        """
        <tr>
          <td>#{escape(name)}</td>
          <td>#{format_bytes(link.s)}</td>
          <td>#{short_hex(hash_hex)}</td>
        </tr>
        """
      end)

    """
    <table class="link-table">
      <thead>
        <tr><th>Name</th><th>Size</th><th>Hash</th></tr>
      </thead>
      <tbody>
        #{Enum.join(rows, "\n")}
      </tbody>
    </table>
    """
  end

  defp hex_to_npub(hex) do
    case Base.decode16(hex, case: :lower) do
      {:ok, bytes} -> Bechamel.encode("npub", bytes)
      :error -> "invalid"
    end
  rescue
    _ -> "invalid"
  end

  defp escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
