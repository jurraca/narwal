defmodule Rhizome.Router do
  @moduledoc """
  Plug router presenting the Nix binary cache HTTP API.

  Endpoints:
  - GET /nix-cache-info — static text
  - GET /<hashpart>.narinfo — resolve via Nostr root + hashtree + Blossom
  - HEAD /<hashpart>.narinfo — existence check
  - GET /nar/<nix32filehash>.nar[.ext] — 302 redirect to Blossom server holding the blob
  - HEAD /nar/<nix32filehash>.nar[.ext] — existence check

  Narinfos are proxied (small, cached in ETS). NARs are redirected, not
  proxied — Nix downloads them directly from Blossom and verifies FileHash.

  Hot path (cache hits): zero GenServer calls — all reads go through ETS.
  Cold path (cache miss): falls back to Blossom fetch in caller process.

  Supports multiple publishers — narinfo reverse index spans all publishers,
  NAR fetches use the union of all publishers' blossom servers.
  """

  use Plug.Router

  require Logger

  alias Rhizome.{Blossom, Dashboard, Manifest, Nix32, RootResolver, Stats, TreeCache}

  plug(:maybe_log)
  plug(:cors)
  plug(Plug.Parsers, parsers: [:urlencoded])
  plug(:match)
  plug(:dispatch)

  get "/" do
    send_resp(conn, 200, "rhizome")
  end

  get "/dashboard" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, Dashboard.render_page())
  end

  get "/dashboard/content" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, Dashboard.render_fragment())
  end

  get "/dashboard/roots" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, Dashboard.render_roots())
  end

  get "/nix-cache-info" do
    body = build_cache_info()
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, body)
  end

  match "/:hashpart.narinfo" do
    case conn.method do
      "GET" -> serve_narinfo(conn, hashpart <> ".narinfo")
      "HEAD" -> check_narinfo(conn, hashpart <> ".narinfo")
      _ -> send_resp(conn, 405, "Method Not Allowed")
    end
  end

  match "/nar/:filehash_and_ext" do
    {nix32_hash, _ext} = split_filehash(filehash_and_ext)

    case conn.method do
      "GET" -> serve_nar(conn, nix32_hash)
      "HEAD" -> check_nar(conn, nix32_hash)
      _ -> send_resp(conn, 405, "Method Not Allowed")
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  ## Narinfo serving

  defp serve_narinfo(conn, name) do
    Stats.incr(:narinfo_requests)

    case resolve_narinfo(name) do
      {:ok, bytes} ->
        conn
        |> put_resp_content_type("text/x-nix-narinfo")
        |> send_resp(200, bytes)

      {:error, :not_resolved} ->
        send_resp(conn, 503, "Root not yet resolved")

      {:error, :not_found} ->
        Stats.incr(:narinfo_404s)
        send_resp(conn, 404, "Not Found")

      {:error, reason} ->
        Logger.warning("narinfo #{name} failed: #{inspect(reason)}")
        send_resp(conn, 502, "Bad Gateway")
    end
  end

  defp check_narinfo(conn, name) do
    case resolve_narinfo(name) do
      {:ok, _} ->
        conn
        |> put_resp_header("content-type", "text/x-nix-narinfo")
        |> send_resp(200, "")

      _ ->
        send_resp(conn, 404, "Not Found")
    end
  end

  @doc """
  Resolve a narinfo by name to its blob bytes.

  Hot path: ETS reverse index → ETS narinfo cache (zero GenServer calls).
  Cold path: slow tree walk across all publishers → Blossom fetch.
  """
  def resolve_narinfo(name) do
    case RootResolver.lookup_narinfo(name) do
      {:ok, {hash_hex, servers}} ->
        Stats.incr(:narinfo_hits)
        get_narinfo_bytes(hash_hex, servers)

      :miss ->
        Stats.incr(:narinfo_misses)
        resolve_narinfo_slow(name)
    end
  end

  defp resolve_narinfo_slow(name) do
    case RootResolver.get_roots() do
      {:ok, roots} ->
        roots
        |> Enum.find_value(fn root ->
          with {:ok, node} <- get_tree_node(root.root_hash_hex, root.blossom_servers),
               {:ok, link} <- find_link_recursive(node, name, root.blossom_servers, MapSet.new()) do
            hash_hex = Base.encode16(link.h, case: :lower)
            case get_narinfo_bytes(hash_hex, root.blossom_servers) do
              {:ok, _} = ok -> ok
              {:error, _} -> nil
            end
          else
            _ -> nil
          end
        end)
        |> case do
          nil -> {:error, :not_found}
          result -> result
        end

      {:error, :not_resolved} ->
        {:error, :not_resolved}
    end
  end

  defp find_link_recursive(node, name, servers, visited) do
    case Manifest.find_link(node.l, name) do
      {:ok, link} ->
        {:ok, link}

      :not_found ->
        Enum.find_value(node.l, fn link ->
          if Map.get(link, :t, 0) == 2 do
            child_hash_hex = Base.encode16(link.h, case: :lower)

            if MapSet.member?(visited, child_hash_hex) do
              nil
            else
              visited = MapSet.put(visited, child_hash_hex)

              with {:ok, child_node} <- get_tree_node(child_hash_hex, servers) do
                find_link_recursive(child_node, name, servers, visited)
              else
                _ -> nil
              end
            end
          else
            nil
          end
        end)
    end
  end

  defp get_narinfo_bytes(hash_hex, servers) do
    case TreeCache.lookup_narinfo(hash_hex) do
      {:ok, bytes} -> {:ok, bytes}
      :miss -> TreeCache.fetch_narinfo(hash_hex, servers)
    end
  end

  ## NAR serving

  # NARs are NOT proxied through Rhizome — a NAR can be hundreds of MB, and
  # buffering it in the request process would scale memory with concurrency.
  # Instead we HEAD-probe the Blossom servers for the blob and 302-redirect
  # the Nix client to the server that has it. No trust is lost: Nix verifies
  # the downloaded bytes against the narinfo's FileHash itself.
  defp serve_nar(conn, nix32_hash) do
    Stats.incr(:nar_requests)

    with {:ok, binary_hash} <- Nix32.decode(nix32_hash),
         <<hex_hash::binary-size(32), _::binary>> <- binary_hash,
         hex_str <- Base.encode16(hex_hash, case: :lower),
         servers <- RootResolver.get_blossom_servers(),
         false <- servers == [],
         {:ok, server} <- Blossom.find_blob_server(servers, hex_str) do
      conn
      |> put_resp_header("location", Blossom.blob_url(server, hex_str))
      |> send_resp(302, "")
    else
      {:error, :invalid_character} ->
        send_resp(conn, 400, "Invalid Nix32 hash")

      :not_found ->
        Stats.incr(:nar_404s)
        send_resp(conn, 404, "Not Found")

      true ->
        send_resp(conn, 503, "Root not yet resolved")

      _other ->
        send_resp(conn, 400, "Invalid NAR hash")
    end
  end

  defp check_nar(conn, nix32_hash) do
    with {:ok, binary_hash} <- Nix32.decode(nix32_hash),
         <<hex_hash::binary-size(32), _::binary>> <- binary_hash,
         hex_str <- Base.encode16(hex_hash, case: :lower),
         servers <- RootResolver.get_blossom_servers(),
         false <- servers == [],
         :ok <- Blossom.head_blob(servers, hex_str) do
      conn
      |> put_resp_header("content-type", "application/x-nix-nar")
      |> send_resp(200, "")
    else
      _ -> send_resp(conn, 404, "Not Found")
    end
  end

  ## Helpers

  defp get_tree_node(hex_hash, servers) do
    case TreeCache.lookup_node(hex_hash) do
      {:ok, node} -> {:ok, node}
      :miss -> TreeCache.fetch_node(hex_hash, servers)
    end
  end

  defp split_filehash(path) do
    case String.split(path, ".", parts: 2) do
      [hash, ext] -> {hash, "." <> ext}
      [hash] -> {hash, ""}
    end
  end

  defp build_cache_info do
    priority = Application.get_env(:rhizome, :priority, 30)
    store_dir = Application.get_env(:rhizome, :store_dir, "/nix/store")
    "StoreDir: #{store_dir}\nWantMassQuery: 0\nPriority: #{priority}\n"
  end

  defp maybe_log(conn, _opts) do
    if String.starts_with?(conn.request_path, "/dashboard") do
      conn
    else
      Plug.Logger.call(conn, :info)
    end
  end

  defp cors(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, HEAD, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "*")
  end
end
