defmodule Narwal.TreeCache do
  @moduledoc """
  ETS cache for hashtree tree nodes and narinfo blobs.

  Immutable blobs are cached forever (content-addressed, never change).
  Keyed by hex hash string.

  The GenServer only owns the ETS table — it handles no calls.
  All fetches happen in the caller's process (Bandit request handler),
  so a slow Blossom HTTP fetch blocks only that one request, not others.

  Hot path: lookup_node/1, lookup_narinfo/1 (ETS direct read).
  Cold path: fetch_node/2, fetch_narinfo/2 (ETS miss → Blossom HTTP → ETS insert).
  """

  use GenServer

  alias Narwal.{Blossom, Manifest}

  @table :narwal_tree_cache

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{}}
  end

  @doc """
  Look up a cached tree node by hex hash.
  Returns `{:ok, node}` or `:miss`.
  """
  @spec lookup_node(String.t()) :: {:ok, map()} | :miss
  def lookup_node(hex_hash) do
    case :ets.lookup(@table, {:node, hex_hash}) do
      [{_, node}] -> {:ok, node}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Look up a cached narinfo blob by hex hash.
  Returns `{:ok, bytes}` or `:miss`.
  """
  @spec lookup_narinfo(String.t()) :: {:ok, binary()} | :miss
  def lookup_narinfo(hex_hash) do
    case :ets.lookup(@table, {:narinfo, hex_hash}) do
      [{_, bytes}] -> {:ok, bytes}
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  @doc """
  Insert a tree node into the cache directly (no GenServer call).
  Used by RootResolver when it fetches the manifest during index building.
  """
  @spec insert_node(String.t(), map()) :: true
  def insert_node(hex_hash, node) do
    :ets.insert(@table, {{:node, hex_hash}, node})
  rescue
    ArgumentError -> true
  end

  ## Public API — fetch in caller process (cold path, no GenServer call)

  @doc """
  Fetch and cache a tree node from Blossom.
  Runs in the caller's process — a slow HTTP fetch blocks only this request.
  Concurrent fetches for the same hash may duplicate, but are harmless
  (content-addressed, last ETS write wins).
  """
  @spec fetch_node(String.t(), [String.t()]) :: {:ok, map()} | {:error, term()}
  def fetch_node(hex_hash, blossom_servers) do
    case lookup_node(hex_hash) do
      {:ok, node} ->
        {:ok, node}

      :miss ->
        case Blossom.fetch_blob(blossom_servers, hex_hash) do
          {:ok, bytes} ->
            case Manifest.decode_node(bytes) do
              {:ok, node} ->
                :ets.insert(@table, {{:node, hex_hash}, node})
                {:ok, node}

              {:error, _} = err ->
                err
            end

          {:error, _} = err ->
            err
        end
    end
  end

  @doc """
  Fetch and cache a narinfo blob from Blossom.
  Runs in the caller's process — a slow HTTP fetch blocks only this request.
  """
  @spec fetch_narinfo(String.t(), [String.t()]) :: {:ok, binary()} | {:error, term()}
  def fetch_narinfo(hex_hash, blossom_servers) do
    case lookup_narinfo(hex_hash) do
      {:ok, bytes} ->
        {:ok, bytes}

      :miss ->
        case Blossom.fetch_blob(blossom_servers, hex_hash) do
          {:ok, bytes} ->
            :ets.insert(@table, {{:narinfo, hex_hash}, bytes})
            {:ok, bytes}

          {:error, _} = err ->
            err
        end
    end
  end
end
