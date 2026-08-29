defmodule Narwal.Manifest do
  @moduledoc """
  BUD-16 Hashtree directory manifest decoder.

  A tree node is a MessagePack map with two fields:
  - "t" (u8): node type (2 = Dir)
  - "l" (array): links to child objects

  Each link is a map:
  - "h" (bytes): 32-byte SHA256 hash
  - "n" (string): entry name (for directories)
  - "s" (u64): child byte size
  - "t" (u8): link type (0 = Blob, default)
  """

  @doc """
  Decode a MessagePack tree node into a map.

  Returns `{:ok, %{t: integer, l: [link, ...]}}` where each link is a map
  with keys :h (binary), :n (string | nil), :s (integer), :t (integer).
  """
  @spec decode_node(binary()) :: {:ok, map()} | {:error, term()}
  def decode_node(msgpack_bytes) when is_binary(msgpack_bytes) do
    case Msgpax.unpack(msgpack_bytes) do
      {:ok, %{"t" => type, "l" => links}} when is_list(links) ->
        decoded_links = links |> Enum.map(&decode_link/1) |> Enum.reject(&is_nil/1)
        {:ok, %{t: type, l: decoded_links}}

      {:ok, other} ->
        {:error, {:unexpected_shape, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def decode_node(iolist) when is_list(iolist) do
    decode_node(IO.iodata_to_binary(iolist))
  end

  defp decode_link(%{"h" => h, "n" => n, "s" => s, "t" => t}) do
    %{h: h, n: n, s: s, t: t}
  end

  defp decode_link(%{"h" => h, "s" => s} = link) do
    %{
      h: h,
      n: Map.get(link, "n"),
      s: s,
      t: Map.get(link, "t", 0)
    }
  end

  defp decode_link(_link), do: nil

  @doc """
  Find a link by entry name in a list of decoded links.

  Returns `{:ok, link}` or `:not_found`.
  """
  @spec find_link([map()], String.t()) :: {:ok, map()} | :not_found
  def find_link(links, name) when is_list(links) and is_binary(name) do
    case Enum.find(links, fn link -> link[:n] == name end) do
      nil -> :not_found
      link -> {:ok, link}
    end
  end
end
