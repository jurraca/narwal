defmodule Rhizome.Stats do
  @moduledoc """
  ETS counter table for request statistics.

  The GenServer only owns the table — all increments and reads are
  lock-free ETS operations callable from any process.

  Counters:
    :narinfo_requests  — total narinfo GETs
    :narinfo_hits      — ETS reverse index hits
    :narinfo_misses    — fell through to slow path
    :narinfo_404s      — not found
    :nar_requests      — total NAR GETs (redirects)
    :nar_404s          — not found
  """

  use GenServer

  @table :rhizome_stats

  @counters [
    :narinfo_requests,
    :narinfo_hits,
    :narinfo_misses,
    :narinfo_404s,
    :nar_requests,
    :nar_404s
  ]

  ## Public API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc "Increment a counter by 1 (lock-free)."
  @spec incr(atom()) :: :ok
  def incr(key) do
    :ets.update_counter(@table, key, 1, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Increment a counter by n (lock-free)."
  @spec incr(atom(), integer()) :: :ok
  def incr(key, n) do
    :ets.update_counter(@table, key, n, {key, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Get all counters as a map."
  @spec get_all() :: map()
  def get_all do
    Enum.reduce(@counters, %{}, fn key, acc ->
      val =
        case :ets.lookup(@table, key) do
          [{_, v}] -> v
          [] -> 0
        end

      Map.put(acc, key, val)
    end)
  rescue
    ArgumentError -> %{}
  end

  ## GenServer callbacks

  @impl true
  def init([]) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])

    Enum.each(@counters, fn key ->
      :ets.insert(@table, {key, 0})
    end)

    {:ok, %{}}
  end
end
