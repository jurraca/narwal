defmodule Narwal.HomePage do
  @moduledoc """
  Public home page: the cache directory.

  Two views, both rendered from ETS-resident index state only — no
  Blossom fetches ever happen here:

  - `render_page/1` — `/`: search box + search results (`?q=`) and one
    card per cache ({publisher, channel}), sorted by most recently
    updated.
  - `render_cache_page/3` — `/cache/<pubkey>/<channel>`: the package
    table for one cache, with substring search and pagination. Top-level
    packages (not referenced by any other indexed narinfo) by default,
    `?scope=all` for the full closure.

  Rendering lives in `templates/` — plain EEx compiled against the
  auto-escaping `Narwal.HTML` engine. Conditionals stay in Elixir and
  pick between fragments; templates only interpolate (escaped) or
  compose pre-rendered markup via `raw/1`.

  Package names come from RootResolver's index-time narinfo enrichment
  (see `Narwal.RootResolver.enrich_leaves/1`); entries whose narinfo
  blob could not be parsed are listed under their hashpart with a nil
  name.
  """

  @page_size 100
  @search_cap 50

  @templates Path.join(__DIR__, "home_page/templates")
  @external_resource Path.join(@templates, "layout.eex")
  @external_resource Path.join(@templates, "page.eex")
  @external_resource Path.join(@templates, "card.eex")
  @external_resource Path.join(@templates, "empty.eex")
  @external_resource Path.join(@templates, "caches_section.eex")
  @external_resource Path.join(@templates, "pkgs_section.eex")
  @external_resource Path.join(@templates, "search_pkg_row.eex")
  @external_resource Path.join(@templates, "cache_page.eex")
  @external_resource Path.join(@templates, "pkgs_list.eex")
  @external_resource Path.join(@templates, "pkg_table.eex")
  @external_resource Path.join(@templates, "pkg_row.eex")
  @external_resource Path.join(@templates, "pager.eex")

  require EEx

  EEx.function_from_file(
    :defp,
    :layout_template,
    Path.join(@templates, "layout.eex"),
    [:title, :css, :body],
    engine: Narwal.HTML
  )

  EEx.function_from_file(:defp, :page_template, Path.join(@templates, "page.eex"), [:q, :content],
    engine: Narwal.HTML
  )

  EEx.function_from_file(:defp, :card_template, Path.join(@templates, "card.eex"), [:root],
    engine: Narwal.HTML
  )

  EEx.function_from_file(:defp, :empty_template, Path.join(@templates, "empty.eex"), [:message],
    engine: Narwal.HTML
  )

  EEx.function_from_file(
    :defp,
    :caches_section_template,
    Path.join(@templates, "caches_section.eex"),
    [:caches],
    engine: Narwal.HTML
  )

  EEx.function_from_file(
    :defp,
    :pkgs_section_template,
    Path.join(@templates, "pkgs_section.eex"),
    [:heading, :pkgs],
    engine: Narwal.HTML
  )

  EEx.function_from_file(
    :defp,
    :search_pkg_row_template,
    Path.join(@templates, "search_pkg_row.eex"),
    [:pkg],
    engine: Narwal.HTML
  )

  EEx.function_from_file(
    :defp,
    :cache_page_template,
    Path.join(@templates, "cache_page.eex"),
    [:body],
    engine: Narwal.HTML
  )

  EEx.function_from_file(
    :defp,
    :pkgs_list_template,
    Path.join(@templates, "pkgs_list.eex"),
    [
      :npub,
      :channel,
      :channel_path_seg,
      :filtered_count,
      :updated,
      :toggle,
      :q,
      :content,
      :pager
    ],
    engine: Narwal.HTML
  )

  EEx.function_from_file(
    :defp,
    :pkg_table_template,
    Path.join(@templates, "pkg_table.eex"),
    [:rows],
    engine: Narwal.HTML
  )

  EEx.function_from_file(:defp, :pkg_row_template, Path.join(@templates, "pkg_row.eex"), [:pkg],
    engine: Narwal.HTML
  )

  EEx.function_from_file(
    :defp,
    :pager_template,
    Path.join(@templates, "pager.eex"),
    [:page, :total_pages, :prev, :next],
    engine: Narwal.HTML
  )

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
  .search-heading {
    color: var(--dim);
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 1px;
    margin: 16px 0 8px;
  }
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

  @doc "Render the cache directory (`/`), with search results when `q` is set."
  @spec render_page(map()) :: binary()
  def render_page(query_params) do
    roots = get_roots()
    q = safe_trim(query_params["q"])

    body =
      if roots == [] do
        empty_template("No caches resolved yet.")
      else
        [search_results_html(q), cards_html(roots)] |> Enum.join("\n")
      end

    layout_template("Nix Binary Cache", @css, page_template(q, body))
  end

  defp cards_html(roots) do
    roots
    |> Enum.sort_by(& &1.created_at, :desc)
    |> Enum.map(&card_template/1)
    |> Enum.join("\n")
  end

  ## Search results

  defp search_results_html(""), do: ""

  defp search_results_html(q) do
    %{caches: caches, pkgs: pkgs, pkg_total: total} = search(q)

    if caches == [] and pkgs == [] do
      empty_template("No matches for \"#{q}\".")
    else
      [cache_results_html(caches), pkg_results_html(pkgs, total)]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end
  end

  defp cache_results_html([]), do: ""

  defp cache_results_html(caches), do: caches_section_template(caches)

  defp pkg_results_html([], _total), do: ""

  defp pkg_results_html(pkgs, total) do
    cap_note = if total > length(pkgs), do: " (showing first #{length(pkgs)})", else: ""
    matches = if total == 1, do: "match", else: "matches"
    pkgs_section_template("Packages — #{total} #{matches}#{cap_note}", pkgs)
  end

  @doc """
  Render the package list for one cache (`/cache/<pubkey>/<channel>`).

  `query_params` is the conn's query params: `q` filters by package name
  (substring, case-insensitive), `page` is 1-based.
  """
  @spec render_cache_page(String.t(), String.t(), map()) :: binary()
  def render_cache_page(pubkey, channel, query_params) do
    roots = get_roots()
    pubkey = normalize_pubkey(pubkey)

    root =
      Enum.find(roots, &(&1.pubkey == pubkey and URI.decode(channel_path(&1.channel)) == channel))

    body =
      if root do
        render_packages(root, query_params)
      else
        empty_template("Unknown cache.")
      end

    layout_template(channel, @css, cache_page_template(body))
  end

  ## Package list

  defp render_packages(root, params) do
    pkgs = get_pkgs(root.pubkey, root.channel)
    scope = scope_param(params["scope"])
    scoped = if scope == :all, do: pkgs, else: Enum.filter(pkgs, &Map.get(&1, :top, true))

    q = params["q"] |> safe_trim() |> String.downcase()

    filtered =
      if q == "", do: scoped, else: Enum.filter(scoped, &String.contains?(pkg_key(&1), q))

    filtered = Enum.sort_by(filtered, &pkg_key/1)

    page = page_param(params["page"])
    {rows, prev_page, next_page} = paginate(filtered, page)
    total_pages = total_pages(filtered)

    content =
      if rows == [], do: empty_template("No matching packages."), else: pkg_table_template(rows)

    pkgs_list_template(
      hex_to_npub(root.pubkey),
      channel_label(root.channel),
      channel_path(root.channel),
      length(filtered),
      relative_time(root.created_at),
      scope_toggle(root, scope, q, length(pkgs)),
      q,
      content,
      pager_html(page, total_pages, prev_page, next_page, root, q, scope)
    )
  end

  defp pkg_count(%{pkg_count: total, top_pkg_count: top})
       when is_integer(total) and is_integer(top),
       do: "#{top} packages · #{total} paths"

  defp pkg_count(%{pkg_count: count}) when is_integer(count), do: "#{count} packages"

  defp pkg_count(_building), do: "indexing…"

  defp pager_html(_page, _total_pages, nil, nil, _root, _q, _scope), do: ""

  defp pager_html(page, total_pages, prev_page, next_page, root, q, scope) do
    pager_template(
      page,
      total_pages,
      pager_link(prev_page, "← newer", root, q, scope),
      pager_link(next_page, "older →", root, q, scope)
    )
  end

  defp pager_link(nil, label, _root, _q, _scope), do: "<span class=\"dim\">#{label}</span>"

  defp pager_link(page, label, root, q, scope) do
    "<a href=\"#{page_href(root, page, q, scope)}\">#{label}</a>"
  end

  defp page_href(root, page, q, scope) do
    base =
      "/cache/#{hex_to_npub(root.pubkey)}/#{channel_path(root.channel)}?page=#{page}&scope=#{scope}"

    if q == "" do
      base
    else
      base <> "&q=" <> URI.encode_www_form(q)
    end
  end

  defp scope_toggle(root, :top, q, total),
    do: "<a href=\"#{scope_href(root, "all", q)}\">show all #{total} packages</a>"

  defp scope_toggle(root, :all, q, _total),
    do: "<a href=\"#{scope_href(root, "top", q)}\">top-level only</a>"

  defp scope_href(root, scope, q) do
    base = "/cache/#{hex_to_npub(root.pubkey)}/#{channel_path(root.channel)}?scope=#{scope}"

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

  # name_lc is the pre-lowercased search key (name, or hashpart when unnamed).
  defp pkg_key(pkg), do: Map.get(pkg, :name_lc) || String.downcase(pkg.name || pkg.hashpart)

  # Global search over the ETS-resident index (no fetches).
  #
  # Matches package names (case-insensitive substring, all paths) and
  # caches (npub or channel substring). `pkgs` is capped at
  # `@search_cap` results, `pkg_total` is the uncapped match count.
  @doc false
  @spec search(String.t()) :: %{caches: [map()], pkgs: [map()], pkg_total: non_neg_integer()}
  def search(query) do
    case String.downcase(String.trim(query)) do
      "" ->
        %{caches: [], pkgs: [], pkg_total: 0}

      q ->
        roots = get_roots()

        pkgs = search_pkgs(roots, q)

        %{
          caches: Enum.filter(roots, &cache_matches?(&1, q)),
          pkgs: Enum.take(pkgs, @search_cap),
          pkg_total: length(pkgs)
        }
    end
  end

  defp cache_matches?(root, q) do
    String.contains?(hex_to_npub(root.pubkey), q) or
      String.contains?(String.downcase(channel_label(root.channel)), q)
  end

  defp search_pkgs(roots, q) do
    roots
    |> Enum.flat_map(fn root ->
      get_pkgs(root.pubkey, root.channel)
      |> Enum.filter(&String.contains?(pkg_key(&1), q))
      |> Enum.map(&Map.merge(&1, %{pubkey: root.pubkey, channel: root.channel}))
    end)
    |> Enum.sort_by(&pkg_key/1)
  end

  # Top-level only (default) or the full closure.
  defp scope_param("all"), do: :all
  defp scope_param(_), do: :top

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

  # Card links use npubs, the index keys roots by hex pubkey — normalize
  # either form to hex before matching. An undecodable npub falls through
  # and simply fails the lookup ("Unknown cache").
  defp normalize_pubkey("npub1" <> _ = npub) do
    case NostrCore.Bech32.decode(npub) do
      {:ok, "npub", hex} -> hex
      _ -> npub
    end
  end

  defp normalize_pubkey(hex), do: hex

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
end
