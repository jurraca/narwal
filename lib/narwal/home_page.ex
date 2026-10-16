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
  @group_re ~r/\B(?=(\d{3})+(?!\d))/

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
  @external_resource Path.join(@templates, "sig_key.eex")
  @external_resource Path.join(@templates, "keys_config.eex")

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
      :base_url,
      :sig_keys_html,
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

  EEx.function_from_file(:defp, :sig_key_template, Path.join(@templates, "sig_key.eex"), [:key],
    engine: Narwal.HTML
  )

  EEx.function_from_file(
    :defp,
    :keys_config_template,
    Path.join(@templates, "keys_config.eex"),
    [:keys],
    engine: Narwal.HTML
  )

  @css """
  :root {
    --paper: #f5f4ec;
    --paper-deep: #eeede3;
    --ink: #263733;
    --muted: #707d76;
    --line: #d9ded3;
    --line-strong: #c8d1c6;
    --sea: #287e70;
    --sea-dark: #1e655a;
    --sea-pale: #e1eee8;
    --sun: #d9a65b;
    --card: #fbfaf5;
    --font-display: Futura, "Futura PT", "Avenir Next", Avenir, "Century Gothic", "Trebuchet MS", sans-serif;
    --font-body: "Avenir Next", Avenir, "Segoe UI", sans-serif;
    --font-mono: "SFMono-Regular", Consolas, "Liberation Mono", monospace;
    --content: 1120px;
  }
  * { box-sizing: border-box; }
  html { scroll-behavior: smooth; }
  body {
    margin: 0;
    min-height: 100vh;
    color: var(--ink);
    background:
      radial-gradient(ellipse at 84% 12%, rgba(205, 225, 213, .4), transparent 26rem),
      var(--paper);
    font-family: var(--font-body);
    -webkit-font-smoothing: antialiased;
  }
  a { color: inherit; }
  .shell { width: min(calc(100% - 64px), var(--content)); margin-inline: auto; }
  .topbar {
    height: 84px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    border-bottom: 1px solid var(--line);
  }
  .wordmark {
    color: var(--ink);
    font-family: var(--font-display);
    font-size: 25px;
    font-weight: 700;
    letter-spacing: -.075em;
    text-decoration: none;
    line-height: 1;
  }
  .wordmark span { color: var(--sea); }
  .nav { display: flex; align-items: center; gap: 31px; }
  .nav a {
    color: #61716b;
    font-size: 13px;
    font-weight: 550;
    text-decoration: none;
    transition: color .18s ease;
  }
  .nav a:hover { color: var(--sea-dark); }
  .intro {
    padding: 50px 0 49px;
    display: grid;
    grid-template-columns: minmax(0, 1fr) 255px;
    gap: 44px;
    align-items: end;
  }
  .intro h1 {
    max-width: 690px;
    margin: 0;
    font-family: var(--font-display);
    font-size: clamp(40px, 5.2vw, 60px);
    font-weight: 600;
    letter-spacing: -.065em;
    line-height: .99;
  }
  .intro h1 em { color: var(--sea); font-style: normal; }
  .lede {
    max-width: 590px;
    margin: 22px 0 0;
    color: #66756e;
    font-size: 16px;
    line-height: 1.7;
    letter-spacing: -.012em;
  }
  .intro-note {
    position: relative;
    padding: 16px 0 4px 20px;
    border-left: 1px solid var(--line-strong);
    color: #68776f;
    font-size: 12px;
    line-height: 1.7;
  }
  .intro-note .note-mark {
    display: block;
    width: 7px;
    height: 7px;
    margin-bottom: 10px;
    border-radius: 50%;
    background: var(--sun);
    box-shadow: 0 0 0 4px rgba(217,166,91,.13);
  }
  .intro-note b { color: var(--ink); font-weight: 650; }
  .directory-head {
    display: flex;
    justify-content: space-between;
    align-items: end;
    padding: 17px 0 13px;
    border-top: 1px solid var(--line-strong);
  }
  .section-title {
    margin: 0;
    font-family: var(--font-display);
    font-size: 21px;
    font-weight: 650;
    letter-spacing: -.045em;
  }
  .section-caption { margin: 4px 0 0; color: #65746d; font-size: 12px; }
  .directory-total {
    color: #66756d;
    font-family: var(--font-mono);
    font-size: 10px;
    letter-spacing: .08em;
    text-transform: uppercase;
    white-space: nowrap;
  }
  .cache-list { display: grid; gap: 10px; padding-bottom: 26px; }
  .cache-card {
    position: relative;
    display: grid;
    grid-template-columns: minmax(0, 1fr) 190px 152px 36px;
    align-items: center;
    gap: 22px;
    padding: 21px 22px 20px 24px;
    border: 1px solid var(--line);
    border-radius: 7px;
    background: rgba(251, 250, 245, .82);
    text-decoration: none;
    transition: transform .2s ease, border-color .2s ease, background .2s ease, box-shadow .2s ease;
    animation: arrive .55s both;
  }
  .cache-card:nth-child(2) { animation-delay: .06s; }
  .cache-card:nth-child(3) { animation-delay: .12s; }
  .cache-card:nth-child(4) { animation-delay: .18s; }
  .cache-card::before {
    position: absolute;
    inset: 12px auto 12px -1px;
    width: 3px;
    border-radius: 0 3px 3px 0;
    background: transparent;
    content: "";
    transition: background .2s ease;
  }
  .cache-card:hover, .cache-card:focus-visible {
    z-index: 1;
    transform: translateY(-2px);
    border-color: #a9c9b9;
    background: #fffef9;
    box-shadow: 0 9px 24px rgba(42, 67, 57, .07);
    outline: none;
  }
  .cache-card:hover::before, .cache-card:focus-visible::before { background: var(--sea); }
  .cache-main { min-width: 0; }
  .cache-name-line { display: flex; align-items: center; gap: 10px; margin-bottom: 8px; }
  .cache-name {
    flex: 1;
    min-width: 0;
    overflow: hidden;
    color: #263a34;
    font-family: var(--font-mono);
    font-size: 12px;
    font-weight: 550;
    letter-spacing: -.04em;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .channel {
    flex: 0 0 auto;
    padding: 4px 7px;
    color: #54746a;
    background: #edf3eb;
    border-radius: 3px;
    font-family: var(--font-mono);
    font-size: 9px;
    letter-spacing: .025em;
  }
  .metrics { display: flex; flex-direction: column; gap: 5px; }
  .metric-line { display: flex; align-items: baseline; gap: 7px; }
  .metric-value { color: #344a41; font-size: 13px; font-weight: 650; letter-spacing: -.02em; }
  .metric-label { color: #63746b; font-size: 10px; }
  .size-value { color: #536d62; font-variant-numeric: tabular-nums; }
  .updated { color: #64746b; font-size: 11px; line-height: 1.5; }
  .updated small { display: block; margin-bottom: 2px; color: #78847b; font-size: 9px; letter-spacing: .08em; text-transform: uppercase; }
  .sig-key-line { margin-bottom: 2px; display: flex; align-items: center; gap: 8px; min-width: 0; }
  .sig-key {
    display: inline-block;
    max-width: 100%;
    overflow: hidden;
    font-family: var(--font-mono);
    font-size: 11px;
    letter-spacing: -.02em;
    color: #344a41;
    text-overflow: ellipsis;
    white-space: nowrap;
  }
  .copy-btn {
    flex: 0 0 auto;
    padding: 3px 9px;
    color: #54746a;
    border: 1px solid #c8d1c6;
    border-radius: 4px;
    background: rgba(250, 250, 244, .55);
    font-family: var(--font-mono);
    font-size: 9px;
    letter-spacing: .04em;
    cursor: pointer;
    user-select: none;
    transition: color .18s ease, border-color .18s ease, background .18s ease;
  }
  .copy-btn:hover { color: var(--sea-dark); border-color: #a9c9b9; background: #fffef9; }
  .copy-btn.copied { color: var(--sea-dark); border-color: var(--sea); background: var(--sea-pale); }
  .open-arrow {
    width: 32px;
    height: 32px;
    display: grid;
    place-items: center;
    color: #789188;
    border: 1px solid #e0e5dc;
    border-radius: 50%;
    transition: color .2s ease, background .2s ease, transform .2s ease, border-color .2s ease;
  }
  .cache-card:hover .open-arrow, .cache-card:focus-visible .open-arrow {
    transform: translateX(2px);
    color: white;
    background: var(--sea);
    border-color: var(--sea);
  }
  .open-arrow svg { width: 14px; height: 14px; }
  .directory-foot {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 20px;
    padding: 15px 2px 23px;
    border-top: 1px solid var(--line);
    color: #64736b;
    font-size: 11px;
    line-height: 1.6;
  }
  .directory-foot strong { color: #5f7167; font-weight: 600; }
  .bottom-band {
    margin-top: 29px;
    padding: 21px 0 26px;
    border-top: 1px solid var(--line);
    display: flex;
    align-items: center;
    justify-content: space-between;
    color: #66746b;
    font-size: 11px;
  }
  .bottom-brand { color: #62746b; font-family: var(--font-display); font-size: 12px; font-weight: 650; letter-spacing: -.03em; }
  .bottom-brand span { color: var(--sea); }
  .bottom-band p { margin: 0; }
  .search-form { margin: 0 0 18px; }
  .search-form input {
    background: rgba(251, 250, 245, .82);
    color: var(--ink);
    border: 1px solid var(--line-strong);
    border-radius: 6px;
    padding: 10px 14px;
    font-family: var(--font-body);
    font-size: 13px;
    width: 320px;
  }
  .search-form input:focus { outline: none; border-color: #a9c9b9; }
  .search-heading {
    color: #65746d;
    font-family: var(--font-mono);
    font-size: 10px;
    letter-spacing: .08em;
    text-transform: uppercase;
    margin: 18px 0 10px;
  }
  .pkg-table { width: 100%; border-collapse: collapse; }
  .pkg-table th {
    text-align: left;
    color: #65746d;
    font-size: 10px;
    letter-spacing: .08em;
    text-transform: uppercase;
    padding: 4px 8px 4px 0;
    border-bottom: 1px solid var(--line-strong);
  }
  .pkg-table td { padding: 5px 8px 5px 0; vertical-align: top; border-bottom: 1px solid var(--line); font-size: 13px; }
  .pkg-table td.hash { color: #78847d; font-family: var(--font-mono); font-size: 12px; }
  .pkg-table td.size, .pkg-table th.size { text-align: right; font-variant-numeric: tabular-nums; }
  .pager { margin-top: 16px; color: #64736b; font-size: 12px; }
  .dim { color: #78847d; }
  .empty { color: #78847d; font-style: italic; font-size: 13px; }
  .back-link {
    display: inline-block;
    margin-top: 18px;
    color: #61716b;
    font-size: 13px;
    font-weight: 550;
    text-decoration: none;
  }
  .back-link:hover { color: var(--sea-dark); }
  .cache-heading {
    margin: 26px 0 6px;
    display: flex;
    align-items: center;
    gap: 10px;
    font-family: var(--font-mono);
    font-size: 15px;
    font-weight: 550;
    letter-spacing: -.04em;
    color: #263a34;
  }
  .subtitle-line { margin: 0 0 18px; color: #65746d; font-size: 12px; }
  .nix-config {
    margin: 0 0 18px;
    display: flex;
    flex-direction: column;
    gap: 6px;
    padding: 14px 16px;
    border: 1px solid var(--line);
    border-radius: 7px;
    background: rgba(251, 250, 245, .82);
  }
  .config-line { display: flex; align-items: baseline; gap: 10px; min-width: 0; }
  .config-label {
    flex: 0 0 auto;
    color: #65746d;
    font-family: var(--font-mono);
    font-size: 10px;
    letter-spacing: .08em;
    text-transform: uppercase;
    white-space: nowrap;
  }
  .config-value {
    margin: 0;
    color: #344a41;
    font-family: var(--font-mono);
    font-size: 12px;
    letter-spacing: -.02em;
    overflow-wrap: anywhere;
  }
  @keyframes arrive { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: translateY(0); } }
  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after { scroll-behavior: auto !important; animation-duration: .01ms !important; animation-iteration-count: 1 !important; transition-duration: .01ms !important; }
  }
  @media (max-width: 760px) {
    .shell { width: min(calc(100% - 40px), var(--content)); }
    .topbar { height: 72px; }
    .nav { gap: 18px; }
    .intro { padding: 39px 0 38px; grid-template-columns: 1fr; gap: 24px; }
    .intro-note { max-width: 420px; padding-top: 0; padding-bottom: 0; }
    .cache-card { grid-template-columns: minmax(0, 1fr) auto 32px; gap: 12px; padding: 18px; }
    .metrics { grid-column: 1; grid-row: 2; flex-direction: row; gap: 18px; }
    .updated { grid-column: 2; grid-row: 2; text-align: right; }
    .open-arrow { grid-column: 3; grid-row: 1 / span 2; }
    .cache-main { grid-column: 1 / 3; }
    .directory-foot { align-items: flex-start; }
  }
  @media (max-width: 480px) {
    .shell { width: calc(100% - 32px); }
    .wordmark { font-size: 23px; }
    .nav { gap: 12px; }
    .nav a { font-size: 11px; }
    .intro { padding-top: 32px; }
    .intro h1 { font-size: 46px; }
    .lede { font-size: 14px; }
    .search-form input { width: 100%; }
    .directory-head { align-items: flex-start; gap: 12px; flex-direction: column; }
    .directory-total { font-size: 9px; }
    .cache-card { padding: 16px 13px; grid-template-columns: minmax(0,1fr) auto 27px; gap: 10px; }
    .cache-name-line { gap: 7px; }
    .cache-name { font-size: 10px; }
    .channel { padding: 4px 5px; font-size: 8px; }
    .publisher { font-size: 9px; }
    .metrics { gap: 11px; }
    .metric-line { gap: 4px; }
    .metric-value { font-size: 11px; }
    .metric-label { font-size: 9px; }
    .updated { font-size: 10px; }
    .open-arrow { width: 27px; height: 27px; }
    .directory-foot { flex-direction: column; gap: 8px; }
    .bottom-band { gap: 12px; align-items: flex-start; flex-direction: column; }
  }
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
  (substring, case-insensitive), `page` is 1-based. `base_url` is the
  site's own URL (scheme + host), used for the nix config block.
  """
  @spec render_cache_page(String.t(), String.t(), map(), String.t()) :: binary()
  def render_cache_page(pubkey, channel, query_params, base_url) do
    roots = get_roots()
    pubkey = normalize_pubkey(pubkey)

    root =
      Enum.find(roots, &(&1.pubkey == pubkey and URI.decode(channel_path(&1.channel)) == channel))

    body =
      if root do
        render_packages(root, query_params, base_url)
      else
        empty_template("Unknown cache.")
      end

    layout_template(channel, @css, cache_page_template(body))
  end

  ## Package list

  defp render_packages(root, params, base_url) do
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
      base_url,
      sig_keys_html(Map.get(root, :nix_sig_keys, [])),
      pager_html(page, total_pages, prev_page, next_page, root, q, scope)
    )
  end

  defp sig_keys_html([]), do: ""

  defp sig_keys_html(keys), do: keys_config_template(Enum.join(keys, " "))

  defp pkg_packages(%{top_pkg_count: top}) when is_integer(top), do: format_count(top)
  defp pkg_packages(_building), do: "indexing…"

  defp pkg_paths(%{pkg_count: count}) when is_integer(count), do: format_count(count)
  defp pkg_paths(_building), do: "—"

  defp pkg_total(%{total_bytes: bytes}) when is_integer(bytes), do: format_bytes(bytes)
  defp pkg_total(_building), do: "—"

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
      diff < 3600 -> minutes_ago(div(diff, 60))
      diff < 86_400 -> hours_ago(div(diff, 3600))
      diff < 2 * 86_400 -> "Yesterday"
      diff < 30 * 86_400 -> "#{div(diff, 86_400)} days ago"
      true -> Calendar.strftime(DateTime.from_unix!(unix_ts, :second), "%Y-%m-%d")
    end
  end

  defp relative_time(_), do: "unknown"

  defp minutes_ago(1), do: "1 minute ago"
  defp minutes_ago(n), do: "#{n} minutes ago"

  defp hours_ago(1), do: "1 hour ago"
  defp hours_ago(n), do: "#{n} hours ago"

  defp format_bytes(nil), do: "—"
  defp format_bytes(0), do: "0"
  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_bytes(bytes) when bytes < 1024 * 1024 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024 do
    "#{Float.round(bytes / (1024 * 1024), 1)} MB"
  end

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024 * 1024 do
    "#{Float.round(bytes / (1024 * 1024 * 1024), 1)} GB"
  end

  defp format_bytes(bytes) do
    "#{Float.round(bytes / (1024 * 1024 * 1024 * 1024), 1)} TB"
  end

  @doc false
  @spec format_count(non_neg_integer()) :: String.t()
  def format_count(n) when is_integer(n) do
    Integer.to_string(n) |> then(&Regex.replace(@group_re, &1, ","))
  end
end
