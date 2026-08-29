defmodule Narwal.RootResolver do
  @moduledoc """
  GenServer that resolves and caches Nostr root events (kind 17091/37091)
  for one or more configured publishers.

  On init, connects to Nostr relays via NostrEx and creates one subscription
  per publisher. Handles incoming events, extracts the htree root hash
  and blossom server list, and caches results in ETS.

  On each root event, publishes the new root to ETS immediately, then builds
  the reverse index (narinfo name → blob hash + servers) asynchronously in a
  Task.Supervisor task. The tree walk does blocking Blossom HTTP fetches, so
  it must not run inside this GenServer.

  The task performs no index mutation — it returns a staging list of entries.
  On completion the GenServer commits the index in one fast ETS-only pass:
  clear old keys, insert new ones. The previous index stays live during the
  build, and superseded builds (replaced by a newer event mid-flight) are
  cancelled and their results discarded.

  All reads go through ETS directly — no GenServer calls on the hot path.
  The GenServer only handles Nostr subscriptions and index commits.

  Supports multiple publishers via RHIZOME_PUBLISHER_NPUBS (comma-separated).
  """

  use GenServer

  require Logger

  alias Narwal.{Blossom, Manifest, Nhash}

  @table :narwal_roots
  @refresh_ttl :timer.minutes(5)

  ## Public API (ETS direct reads — no GenServer call)

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Get the first resolved root (backward compat for single-publisher).

  Returns `{:ok, root_map}` or `{:error, :not_resolved}`.
  """
  @spec get_root() :: {:ok, map()} | {:error, :not_resolved}
  def get_root do
    case :ets.match(@table, {{:root, :_}, :"$1"}) do
      [[root | _] | _] -> {:ok, root}
      [] -> {:error, :not_resolved}
    end
  rescue
    ArgumentError -> {:error, :not_resolved}
  end

  @doc """
  Get all resolved roots.

  Returns `{:ok, [root_map, ...]}` or `{:error, :not_resolved}`.
  """
  @spec get_roots() :: {:ok, [map()]} | {:error, :not_resolved}
  def get_roots do
    case :ets.match(@table, {{:root, :_}, :"$1"}) do
      [] -> {:error, :not_resolved}
      rows -> {:ok, Enum.map(rows, &hd/1)}
    end
  rescue
    ArgumentError -> {:error, :not_resolved}
  end

  @doc """
  Get the union of all publishers' blossom servers.

  Returns a list of server URLs (may be empty if no roots resolved).
  Used for NAR blob fetches — NARs are content-addressed, any server
  that has the blob can serve it.
  """
  @spec get_blossom_servers() :: [String.t()]
  def get_blossom_servers do
    case :ets.lookup(@table, :blossom_servers) do
      [{:blossom_servers, servers}] -> servers
      [] -> []
    end
  rescue
    ArgumentError -> []
  end

  @doc """
  Look up a narinfo by name in the reverse index.

  Returns `{:ok, {narinfo_hash_hex, blossom_servers}}` or `:miss`.
  On miss, the caller should fall back to the slow path (roots → tree nodes → find_link).
  """
  @spec lookup_narinfo(String.t()) :: {:ok, {String.t(), [String.t()]}} | :miss
  def lookup_narinfo(name) do
    case :ets.lookup(@table, {:narinfo, name}) do
      [{_, result}] -> {:ok, result}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  ## GenServer callbacks

  @impl true
  def init(config) do
    table = :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])

    state = %{
      config: config,
      roots: %{},
      subs: %{},
      building: %{},
      table: table
    }

    npubs = config[:npubs] || []

    if npubs != [] and config[:relays] && config[:relays] != [] do
      send(self(), :connect)
    else
      Logger.info("RootResolver: no publisher configured, running in passive mode")
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    %{npubs: npubs, relays: relays, channel: channel} = state.config

    Enum.each(relays, fn relay_url ->
      case NostrEx.connect(relay_url) do
        {:ok, _name} ->
          Logger.info("RootResolver: connected to #{relay_url}")

        {:error, reason} ->
          Logger.warning("RootResolver: failed to connect to #{relay_url}: #{inspect(reason)}")
      end
    end)

    subs =
      Enum.reduce(npubs, %{}, fn npub, acc ->
        with {:ok, "npub", hex_id} <- NostrCore.Bech32.decode(npub),
             filter = build_filter(hex_id, channel),
             {:ok, sub} <- NostrEx.create_sub(filter) do
          NostrEx.send_sub(sub)
          Logger.info("RootResolver: subscribed for npub=#{npub}, kind=#{inspect(filter[:kinds])}")
          Map.put(acc, sub.id, hex_id)
        else
          {:error, reason} ->
            Logger.error("RootResolver: failed to subscribe for npub=#{npub}: #{inspect(reason)}")
            acc

          _ ->
            Logger.error("RootResolver: invalid npub=#{npub}")
            acc
        end
      end)

    schedule_refresh()
    {:noreply, %{state | subs: subs}}
  end

  @impl true
  def handle_info({:event, sub_id, event}, state) do
    case Map.get(state.subs, sub_id) do
      nil ->
        Logger.debug("RootResolver: event from unknown sub #{sub_id}")
        {:noreply, state}

      pubkey_hex ->
        case process_event(event, state.config) do
          {:ok, root} ->
            if should_replace?(state.roots[pubkey_hex], root, event.id) do
              Logger.info("RootResolver: resolved root for #{pubkey_hex}: hash=#{root.root_hash_hex}, event=#{event.id}")
              {:noreply, accept_root(state, pubkey_hex, root)}
            else
              Logger.debug("RootResolver: ignored older event #{event.id} for #{pubkey_hex}")
              {:noreply, state}
            end

          {:error, reason} ->
            Logger.warning("RootResolver: rejected event #{inspect(event.id)}: #{inspect(reason)}")
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:eose, _sub_id, _host}, state) do
    {:noreply, state}
  end

  # Task.Supervisor.async_nolink result: index build completed successfully.
  @impl true
  def handle_info({ref, {:ok, index}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case pop_build_by_ref(state, ref) do
      {nil, state} ->
        # Result from a cancelled/superseded build — discard.
        {:noreply, state}

      {pubkey_hex, state} ->
        {:noreply, commit_index(state, pubkey_hex, index)}
    end
  end

  def handle_info({ref, {:error, reason}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {pubkey_hex, state} = pop_build_by_ref(state, ref)

    if pubkey_hex do
      Logger.warning("RootResolver: index build failed for #{pubkey_hex}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case pop_build_by_ref(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {pubkey_hex, state} ->
        Logger.warning("RootResolver: index build crashed for #{pubkey_hex}: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:refresh, state) do
    Logger.debug("RootResolver: periodic refresh")
    schedule_refresh()
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("RootResolver: unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  ## Private functions

  defp build_filter(hex_id, nil) do
    [authors: [hex_id], kinds: [17091]]
  end

  defp build_filter(hex_id, channel) do
    [authors: [hex_id], kinds: [37091], "#d": [channel]]
  end

  defp process_event(event, _config) do
    extract_root(event)
  end

  defp extract_root(%{tags: tags, id: event_id} = event) do
    with {:ok, htree_uri} <- find_tag(tags, "htree"),
         {:ok, %{hash: root_hash}} <- Nhash.decode(htree_uri) do
      root_hash_hex = Base.encode16(root_hash, case: :lower)
      blossom_servers = find_all_tags(tags, "blossom")
      nix_sig_keys = find_all_tags(tags, "nixSigKey")

      {:ok,
       %{
         root_hash: root_hash,
         root_hash_hex: root_hash_hex,
         blossom_servers: blossom_servers,
         nix_sig_keys: nix_sig_keys,
         created_at: event.created_at,
         event_id: event_id
       }}
    else
      {:error, reason} -> {:error, reason}
      :not_found -> {:error, :missing_htree_tag}
    end
  end

  defp extract_root(%{} = _event), do: {:error, "no tags in event"}

  ## Async index build

  # Publish the new root immediately, then build the narinfo index in a
  # Task.Supervisor task. Any in-flight build for this publisher is cancelled
  # first — its result would be stale.
  defp accept_root(state, pubkey_hex, root) do
    state = cancel_build(state, pubkey_hex)

    :ets.insert(state.table, {{:root, pubkey_hex}, root})
    update_blossom_servers(state.table)

    task =
      Task.Supervisor.async_nolink(Narwal.TaskSupervisor, fn ->
        collect_narinfo_index(root)
      end)

    %{
      state
      | roots: Map.put(state.roots, pubkey_hex, root),
        building: Map.put(state.building, pubkey_hex, task)
    }
  end

  defp cancel_build(state, pubkey_hex) do
    case Map.pop(state.building, pubkey_hex) do
      {nil, _building} ->
        state

      {task, building} ->
        Process.demonitor(task.ref, [:flush])
        Task.shutdown(task, :brutal_kill)
        %{state | building: building}
    end
  end

  defp pop_build_by_ref(state, ref) do
    case Enum.find(state.building, fn {_pubkey, task} -> task.ref == ref end) do
      nil ->
        {nil, state}

      {pubkey_hex, _task} ->
        {pubkey_hex, %{state | building: Map.delete(state.building, pubkey_hex)}}
    end
  end

  # Commit a completed build. Pure ETS operations — fast even for large
  # trees. The old index stays live until this point.
  defp commit_index(state, pubkey_hex, index) do
    %{link_count: link_count, total_bytes: total_bytes, entries: entries} = index

    clear_narinfo_index(state.table, pubkey_hex)

    if entries != [] do
      :ets.insert(state.table, entries)
    end

    narinfo_keys = Enum.map(entries, &elem(&1, 0))
    :ets.insert(state.table, {{:narinfo_keys, pubkey_hex}, narinfo_keys})

    updated_root =
      state.roots
      |> Map.fetch!(pubkey_hex)
      |> Map.merge(%{link_count: link_count, total_bytes: total_bytes})

    :ets.insert(state.table, {{:root, pubkey_hex}, updated_root})
    %{state | roots: Map.put(state.roots, pubkey_hex, updated_root)}
  end

  # Runs in the build task: fetch the root manifest and walk the tree,
  # returning a staging list of entries. No index mutation happens here —
  # the only shared writes are idempotent TreeCache inserts of
  # content-addressed manifest nodes.
  defp collect_narinfo_index(root) do
    case Blossom.fetch_blob(root.blossom_servers, root.root_hash_hex) do
      {:ok, bytes} ->
        case Manifest.decode_node(bytes) do
          {:ok, node} ->
            Narwal.TreeCache.insert_node(root.root_hash_hex, node)

            {link_count, total_bytes, entries} =
              walk_dir_collect(root.root_hash_hex, root.blossom_servers, MapSet.new())

            Logger.info("RootResolver: built index with #{link_count} entries, #{total_bytes} bytes")
            {:ok, %{link_count: link_count, total_bytes: total_bytes, entries: entries}}

          {:error, reason} ->
            {:error, {:manifest_decode_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:manifest_fetch_failed, reason}}
    end
  end

  @doc false
  @spec walk_dir_collect(String.t(), [String.t()], MapSet.t()) ::
          {non_neg_integer(), non_neg_integer(), [tuple()]}
  def walk_dir_collect(hash_hex, servers, visited \\ MapSet.new()) do
    if MapSet.member?(visited, hash_hex) do
      {0, 0, []}
    else
      visited = MapSet.put(visited, hash_hex)

      case get_node(hash_hex, servers) do
        {:ok, node} ->
          Narwal.TreeCache.insert_node(hash_hex, node)

          Enum.reduce(node.l, {0, 0, []}, fn link, {count, bytes, entries} ->
            link_type = Map.get(link, :t, 0)

            if link_type == 2 do
              child_hash_hex = Base.encode16(link.h, case: :lower)

              {child_count, child_bytes, child_entries} =
                walk_dir_collect(child_hash_hex, servers, visited)

              {count + child_count, bytes + child_bytes, entries ++ child_entries}
            else
              # Skip links without a name — they are chunks, not narinfo entries.
              if is_binary(link.n) do
                child_hash_hex = Base.encode16(link.h, case: :lower)
                entry = {{:narinfo, link.n}, {child_hash_hex, servers}}
                {count + 1, bytes + link.s, [entry | entries]}
              else
                {count, bytes, entries}
              end
            end
          end)

        {:error, _} ->
          {0, 0, []}
      end
    end
  end

  defp get_node(hash_hex, servers) do
    case Narwal.TreeCache.lookup_node(hash_hex) do
      {:ok, node} -> {:ok, node}
      :miss -> fetch_and_cache_node(hash_hex, servers)
    end
  end

  defp fetch_and_cache_node(hash_hex, servers) do
    case Blossom.fetch_blob(servers, hash_hex) do
      {:ok, bytes} ->
        case Manifest.decode_node(bytes) do
          {:ok, node} ->
            Narwal.TreeCache.insert_node(hash_hex, node)
            {:ok, node}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  defp update_blossom_servers(table) do
    servers =
      :ets.match(table, {{:root, :_}, :"$1"})
      |> Enum.map(&hd/1)
      |> Enum.flat_map(& &1.blossom_servers)
      |> Enum.uniq()

    :ets.insert(table, {:blossom_servers, servers})
  end

  defp find_tag(tags, name) do
    case Enum.find(tags, fn
           %NostrCore.Tag{type: n} -> n == name
           [n | _] -> n == name
           _ -> false
         end) do
      %NostrCore.Tag{data: data} -> {:ok, data}
      [_, data | _] -> {:ok, data}
      nil -> :not_found
    end
  end

  defp find_all_tags(tags, name) do
    tags
    |> Enum.filter(fn
      %NostrCore.Tag{type: n} -> n == name
      [n | _] -> n == name
      _ -> false
    end)
    |> Enum.map(fn
      %NostrCore.Tag{data: data} -> data
      [_, data | _] -> data
    end)
  end

  defp should_replace?(nil, _new_root, _new_event_id), do: true

  defp should_replace?(existing_root, new_root, new_event_id) do
    existing_created_at = Map.get(existing_root, :created_at, 0)
    new_created_at = new_root.created_at

    cond do
      new_created_at > existing_created_at -> true
      new_created_at < existing_created_at -> false
      true ->
        existing_event_id = Map.get(existing_root, :event_id) || ""
        new_event_id = new_event_id || ""
        new_event_id > existing_event_id
    end
  end

  defp clear_narinfo_index(table, pubkey_hex) do
    case :ets.lookup(table, {:narinfo_keys, pubkey_hex}) do
      [{_, keys}] ->
        Enum.each(keys, fn key -> :ets.delete(table, key) end)
        :ets.delete(table, {:narinfo_keys, pubkey_hex})

      [] ->
        :ok
    end
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_ttl)
  end
end
