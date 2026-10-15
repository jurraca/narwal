defmodule Narwal.HomePage do
  @moduledoc """
  Public home page: the cache directory.

  Two views, both rendered from ETS-resident index state only — no
  Blossom fetches ever happen here:

  - `render_page/0` — `/`: one card per cache ({publisher, channel}),
    sorted by most recently updated.
  - `render_cache_page/3` — `/cache/<pubkey>/<channel>`: the package
    table for one cache, with substring search and pagination.

  Package names come from RootResolver's index-time narinfo enrichment
  (see `Narwal.RootResolver.enrich_leaves/1`); entries whose narinfo
  blob could not be parsed are listed under their hashpart with a nil
  name.
  """

  @page_size 100

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
  .dim { color: var(--dim); }
  a { color: var(--accent); text-decoration: none; }
  a:hover { text-decoration: underline; }
  .cache-card {
    border: 1px solid var(--border);
    padding: 14px 16px;
    border-radius: 4px;
    margin-bottom: 12px;
    display: block;
  }
  .cache-card:hover { border-color: var(--accent); }
  .cache-npub { color: var(--accent); font-weight: bold; font-size: 12px; word-break: break-all; }
  .cache-meta { color: var(--dim); font-size: 12px; margin-top: 6px; }
  .cache-stats { display: flex; gap: 16px; margin-top: 8px; color: var(--green); font-size: 12px; }
  .search-form { margin: 16px 0; }
  .search-form input {
    background: var(--bg);
    color: var(--fg);
    border: 1px solid var(--border);
    border-radius: 4px;
    padding: 6px 10px;
    font-family: inherit;
    font-size: 13px;
    width: 320px;
  }
  .pkg-table { width: 100%; border-collapse: collapse; }
  .pkg-table th {
    text-align: left;
    color: var(--dim);
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 1px;
    padding: 4px 8px 4px 0;
    border-bottom: 1px solid var(--border);
  }
  .pkg-table td { padding: 4px 8px 4px 0; vertical-align: top; }
  .pkg-table td.hash { color: var(--dim); }
  .pkg-table td.size, .pkg-table th.size { text-align: right; }
  .pager { margin-top: 16px; color: var(--dim); font-size: 12px; }
  .empty { color: var(--dim); font-style: italic; }
  """

  @doc "Render the cache directory (`/`)."
  @spec render_page() :: binary()
  def render_page do
    roots = get_roots()

    body =
      if roots == [] do
        "<p class=\"empty\">No caches resolved yet.</p>"
      else
        roots
        |> Enum.sort_by(& &1.created_at, :desc)
        |> Enum.map(&render_cache_card/1)
        |> Enum.join("\n")
      end

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Narwal — Nix Binary Cache</title>
    <style>#{@css}</style>
    </head>
    <body>
    <h1>Narwal</h1>
    <div class="subtitle">Nix binary cache index — Nostr + Blossom</div>
    #{body}
    </body>
    </html>
    """
  end

  @doc """
  Render the package list for one cache (`/cache/<pubkey>/<channel>`).

  `query_params` is the conn's query params: `q` filters by package name
  (substring, case-insensitive), `page` is 1-based.
  """
  @spec render_cache_page(String.t(), String.t(), map()) :: binary()
  def render_cache_page(pubkey, channel, query_params) do
    roots = get_roots()

    root = Enum.find(roots, &(&1.pubkey == pubkey and channel_path(&1.channel) == channel))

    body =
      if root do
        render_packages(root, query_params)
      else
        "<p class=\"empty\">Unknown cache.</p>"
      end

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Narwal — #{escape(channel)}</title>
    <style>#{@css}</style>
    </head>
    <body>
    <div class="subtitle"><a href="/">← all caches</a></div>
    #{body}
    </body>
    </html>
    """
  end

  ## Cache directory

  defp render_cache_card(root) do
    """
    <a class="cache-card" href="/cache/#{escape(channel_path(root.channel))}">
      <div class="cache-npub">#{escape(hex_to_npub(root.pubkey))}</div>
      <div class="cache-meta">channel: #{escape(channel_label(root.channel))}</div>
      <div class="cache-stats">
        <span>#{pkg_count(root)}</span>
        <span>#{format_bytes(Map.get(root, :total_bytes, 0))}</span>
        <span>updated #{relative_time(root.created_at)}</span>
      </div>
    </a>
    """
  end

  defp pkg_count(%{pkg_count: count}) when is_integer(count), do: "#{count} packages"
  defp pkg_count(_building), do: "indexing…"

  ## Package list

  defp render_packages(root, params) do
    pkgs = get_pkgs(root.pubkey, root.channel)

    q = params["q"] |> safe_trim() |> String.downcase()
    filtered = if q == "", do: pkgs, else: Enum.filter(pkgs, &String.contains?(pkg_key(&1), q))
    filtered = Enum.sort_by(filtered, &pkg_key/1)

    page = page_param(params["page"])
    {rows, prev_page, next_page} = paginate(filtered, page)
    total_pages = total_pages(filtered)

    """
    <h1>#{escape(hex_to_npub(root.pubkey))}</h1>
    <div class="subtitle">
      channel: #{escape(channel_label(root.channel))} ·
      #{length(filtered)} packages · updated #{relative_time(root.created_at)}
    </div>
    <form class="search-form" method="get" action="/cache/#{escape(channel_path(root.channel))}">
      <input type="text" name="q" value="#{escape(q)}" placeholder="search packages…">
    </form>
    #{rows_html(rows)}
    #{pager_html(page, total_pages, prev_page, next_page, root, q)}
    """
  end

  defp rows_html([]), do: "<p class=\"empty\">No matching packages.</p>"

  defp rows_html(rows) do
    """
    <table class="pkg-table">
      <thead>
        <tr><th>Package</th><th>Hashpart</th><th class="size">Size</th></tr>
      </thead>
      <tbody>
    #{Enum.map_join(rows, "\n", &render_pkg_row/1)}
      </tbody>
    </table>
    """
  end

  defp render_pkg_row(pkg) do
    name = pkg.name || pkg.hashpart

    """
    <tr>
      <td>#{escape(name)}</td>
      <td class="hash"><a href="/#{escape(pkg.hashpart)}.narinfo">#{escape(pkg.hashpart)}</a></td>
      <td class="size">#{format_bytes(pkg.size)}</td>
    </tr>
    """
  end

  defp pager_html(page, total_pages, prev_page, next_page, root, q) do
    cond do
      prev_page == nil and next_page == nil ->
        ""

      true ->
        """
        <div class="pager">
          #{pager_link(prev_page, "← newer", root, q)}
          &nbsp;page #{page} of #{total_pages}&nbsp;
          #{pager_link(next_page, "older →", root, q)}
        </div>
        """
    end
  end

  defp pager_link(nil, label, _root, _q), do: "<span class=\"dim\">#{label}</span>"

  defp pager_link(page, label, root, q) do
    "<a href=\"#{page_href(root, page, q)}\">#{label}</a>"
  end

  defp page_href(root, page, q) do
    base = "/cache/#{channel_path(root.channel)}?page=#{page}"

    if q == "" do
      base
    else
      base <> "&q=" <> URI.encode_www_form(q)
    end
  end

  defp paginate(pkgs, page) do
    rows = Enum.slice(pkgs, (page - 1) * @page_size, @page_size)
    prev_page = if page > 1, do: page - 1
    next_page = if page * @page_size < length(pkgs), do: page + 1
    {rows, prev_page, next_page}
  end

  defp total_pages([]), do: 1
  defp total_pages(pkgs), do: div(length(pkgs) - 1, @page_size) + 1

  defp pkg_key(pkg), do: String.downcase(pkg.name || pkg.hashpart)

  ## Data access

  defp get_roots do
    case :ets.match(:narwal_roots, {{:root, :"$1", :"$2"}, :"$3"}) do
      [] ->
        []

      rows ->
        Enum.map(rows, fn [pubkey, channel, root] ->
          root |> Map.put(:pubkey, pubkey) |> Map.put(:channel, channel)
        end)
    end
  rescue
    ArgumentError -> []
  end

  defp get_pkgs(pubkey, channel) do
    case :ets.lookup(:narwal_roots, {:pkgs, pubkey, channel}) do
      [{_, pkgs}] -> pkgs
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  ## Helpers

  defp channel_label(:default), do: "default"
  defp channel_label(channel), do: channel

  # Path segment for a channel — channels are arbitrary strings, so
  # percent-encode; Plug decodes on the way back in.
  defp channel_path(:default), do: "default"
  defp channel_path(channel), do: URI.encode(channel)

  defp safe_trim(str) when is_binary(str), do: String.trim(str)
  defp safe_trim(_), do: ""

  defp page_param(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {page, ""} when page >= 1 -> page
      _ -> 1
    end
  end

  defp page_param(_), do: 1

  defp hex_to_npub(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> Bechamel.encode("npub", bytes)
      :error -> hex
    end
  rescue
    _ -> hex
  end

  defp relative_time(unix_ts) when is_integer(unix_ts) do
    diff = System.os_time(:second) - unix_ts

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 30 * 86_400 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(DateTime.from_unix!(unix_ts, :second), "%Y-%m-%d")
    end
  end

  defp relative_time(_), do: "unknown"

  defp format_bytes(nil), do: "—"
  defp format_bytes(0), do: "0"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_bytes(bytes) when bytes < 1024 * 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes) do
    "#{Float.round(bytes / (1024 * 1024), 1)} MB"
  end

  defp escape(str) when is_binary(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  defp escape(_), do: ""
end
