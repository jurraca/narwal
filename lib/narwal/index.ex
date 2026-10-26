defmodule Narwal.Index do
  @moduledoc """
  Read access to the ETS-resident index, for consumers outside this
  application (e.g. the narwal-web frontend).

  Zero-cost reads: plain ETS operations, no GenServer calls.
  """

  @table :narwal_roots

  @doc """
  All indexed roots, as maps with `pubkey` and `channel` merged in.
  """
  @spec roots() :: [map()]
  def roots do
    case :ets.match(@table, {{:root, :"$1", :"$2"}, :"$3"}) do
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

  @doc "Package entries for one cache, ordered as indexed."
  @spec pkgs(binary(), atom() | binary()) :: [map()]
  def pkgs(pubkey, channel) do
    case :ets.lookup(@table, {:pkgs, pubkey, channel}) do
      [{_, pkgs}] -> pkgs
      [] -> []
    end
  rescue
    ArgumentError -> []
  end
end
