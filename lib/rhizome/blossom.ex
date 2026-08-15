defmodule Rhizome.Blossom do
  @moduledoc """
  Inline Blossom blob fetch client (BUD-01).

  Fetches blobs via `GET <server>/<sha256hex>` and verifies SHA256 of the
  response body matches the requested hash. No external Blossom library dep.
  """

  require Logger

  @doc """
  Fetch a blob from a list of Blossom servers, trying each in order.

  Returns `{:ok, binary}` if the blob was found and hash-verified,
  `{:error, :not_found}` if no server had it, or `{:error, reason}`.
  """
  @spec fetch_blob([String.t()], String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch_blob(servers, hash_hex) when is_list(servers) and is_binary(hash_hex) do
    Enum.reduce_while(servers, {:error, :not_found}, fn server, _acc ->
      case fetch_from_server(server, hash_hex) do
        {:ok, body} -> {:halt, {:ok, body}}
        {:error, :not_found} -> {:cont, {:error, :not_found}}
        {:error, reason} ->
          Logger.warning("blossom fetch from #{server} failed: #{inspect(reason)}")
          {:cont, {:error, :not_found}}
      end
    end)
  end

  @doc """
  Check if a blob exists on any Blossom server via `HEAD /<sha256>` (BUD-01).

  Returns `:ok` if any server reports the blob exists, `:not_found` otherwise.
  No body is transferred — use this for existence checks instead of fetch_blob/2.
  """
  @spec head_blob([String.t()], String.t()) :: :ok | :not_found
  def head_blob(servers, hash_hex) when is_list(servers) and is_binary(hash_hex) do
    Enum.reduce_while(servers, :not_found, fn server, _acc ->
      case head_from_server(server, hash_hex) do
        :ok -> {:halt, :ok}
        :not_found -> {:cont, :not_found}
        :error -> {:cont, :not_found}
      end
    end)
  end

  defp head_from_server(server, hash_hex) do
    url = build_url(server, hash_hex)

    case Req.head(url, receive_timeout: 10_000) do
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: status}} when status in [404, 410] ->
        :not_found

      {:ok, %{status: status}} ->
        Logger.warning("blossom HEAD from #{server} returned #{status}")
        :error

      {:error, reason} ->
        Logger.warning("blossom HEAD from #{server} failed: #{inspect(reason)}")
        :error
    end
  end

  defp fetch_from_server(server, hash_hex) do
    url = build_url(server, hash_hex)

    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} ->
        if verify_hash(body, hash_hex) do
          {:ok, body}
        else
          {:error, :hash_mismatch}
        end

      {:ok, %{status: status}} when status in [404, 410] ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp build_url(server, hash_hex) do
    server
    |> String.trim_trailing("/")
    |> Kernel.<>("/")
    |> Kernel.<>(hash_hex)
  end

  defp verify_hash(body, hash_hex) do
    :crypto.hash(:sha256, body)
    |> Base.encode16(case: :lower)
    |> Kernel.==(String.downcase(hash_hex))
  end
end
