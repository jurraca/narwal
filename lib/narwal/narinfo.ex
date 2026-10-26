defmodule Narwal.Narinfo do
  @moduledoc """
  Minimal narinfo text parser.

  Narinfos are small key-value text files (one `"Field: value"` pair per
  line). The index needs three fields: `StorePath:` (package
  identity — the tree itself carries only hashparts), `FileSize:`
  (compressed NAR download size) and `References:` (dependency store
  paths, used to compute which packages are top-level).

  Parsing fails soft: missing or malformed fields yield `nil` (or `[]`
  for references), never errors, so a single odd blob can never break
  index building.
  """

  @doc """
  Parse narinfo text bytes into a small map.

  Returns `%{store_path: String.t() | nil, file_size: non_neg_integer() | nil, references: [String.t()]}`.
  """
  @spec parse(binary()) :: %{
          store_path: String.t() | nil,
          file_size: non_neg_integer() | nil,
          references: [String.t()]
        }
  def parse(bytes) when is_binary(bytes) do
    %{
      store_path: find_field(bytes, "StorePath"),
      file_size: find_int_field(bytes, "FileSize"),
      references: find_field(bytes, "References") |> split_references()
    }
  end

  @doc """
  Split a store path basename into its hashpart and name parts.

  `"<32-char-hash>-hello-2.12.1"` → `{:ok, hashpart, "hello-2.12.1"}`.
  Returns `:error` when the name does not start with a 32-char hashpart
  followed by a dash (e.g. `"nix-cache-info"`).
  """
  @spec split_name(String.t()) :: {:ok, String.t(), String.t()} | :error
  def split_name(basename) when is_binary(basename) do
    case String.split(basename, "-", parts: 2) do
      [hashpart, name] when byte_size(hashpart) == 32 and name != "" ->
        {:ok, hashpart, name}

      _ ->
        :error
    end
  end

  # Prefix with a newline so the first line of the file is findable too
  # (StorePath: is conventionally the first field).
  defp find_field(bytes, field) do
    case :binary.split("\n" <> bytes, "\n#{field}: ") do
      [_, rest] ->
        case :binary.split(rest, "\n") do
          # [value, _]: line followed by more text; [value]: last line
          # without trailing newline
          [value, _] when byte_size(value) > 0 -> value
          [value] when byte_size(value) > 0 -> value
          _ -> nil
        end

      [_] ->
        nil
    end
  end

  defp split_references(nil), do: []
  defp split_references(refs), do: String.split(refs)

  defp find_int_field(bytes, field) do
    case find_field(bytes, field) do
      nil -> nil
      value -> parse_non_neg_int(value)
    end
  end

  defp parse_non_neg_int(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> int
      _ -> nil
    end
  end
end
