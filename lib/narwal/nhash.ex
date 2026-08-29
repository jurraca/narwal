defmodule Narwal.Nhash do
  @moduledoc """
  Decode nhash bech32 identifiers used in htree:// URIs.

  nhash is a bech32-encoded TLV payload with HRP "nhash":
  - TLV type 0: 32-byte hash (required)
  - TLV type 5: 32-byte decryption key (optional, absent for public content)
  """

  @tlv_hash 0
  @tlv_key 5

  @doc """
  Decode an htree:// URI or bare nhash string to a map with :hash and optional :key.

  ## Examples

      iex> {:ok, %{hash: <<0x42::256>>}} = Narwal.Nhash.decode("nhash1qqs2j4ezx3n")
  """
  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(uri_or_nhash) when is_binary(uri_or_nhash) do
    nhash =
      uri_or_nhash
      |> String.trim()
      |> String.trim_leading("htree://")

    case Bechamel.decode(nhash, ignore_length: true) do
      {:ok, "nhash", data} ->
        parse_tlv(data)

      {:ok, hrp, _data} ->
        {:error, {:wrong_hrp, hrp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_tlv(data) do
    case parse_tlv_fields(data, %{}) do
      {:ok, %{hash: _hash} = result} ->
        {:ok, Map.take(result, [:hash, :key])}

      {:ok, _map} ->
        {:error, :missing_hash}

      {:error, _} = err ->
        err
    end
  end

  defp parse_tlv_fields(<<>>, acc), do: {:ok, acc}

  defp parse_tlv_fields(<<@tlv_hash, 32, hash::binary-size(32), rest::binary>>, acc) do
    parse_tlv_fields(rest, Map.put(acc, :hash, hash))
  end

  defp parse_tlv_fields(<<@tlv_key, 32, key::binary-size(32), rest::binary>>, acc) do
    parse_tlv_fields(rest, Map.put(acc, :key, key))
  end

  defp parse_tlv_fields(<<_type, len, _value::binary-size(len), rest::binary>>, acc) do
    # Skip unknown TLV types (forward compatibility)
    parse_tlv_fields(rest, acc)
  end

  defp parse_tlv_fields(_, _acc), do: {:error, :invalid_tlv}
end
