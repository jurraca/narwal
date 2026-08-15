defmodule Rhizome.Nix32 do
  @moduledoc """
  Nix32 encoding — Nix's variant of Base32.

  Alphabet: `0123456789abcdfghijklmnpqrsvwxyz` (32 chars, letters e/o/u/t omitted).
  Processes bytes from the end (last byte first), 5 bits per character.

  Reference: https://github.com/NixOS/nix/blob/master/doc/manual/source/protocols/nix32.md
  """

  @alphabet "0123456789abcdfghijklmnpqrsvwxyz"
  @reverse_map (String.graphemes(@alphabet)
                |> Enum.with_index()
                |> Enum.map(fn {ch, idx} -> {ch, idx} end)
                |> Map.new())

  @doc """
  Decode a Nix32 string to raw bytes.

  Characters are processed right-to-left (last char first), each contributing
  5 bits. Bits are packed into bytes starting from the least significant bits.

  ## Examples

      iex> {:ok, bytes} = Rhizome.Nix32.decode("0f3q75ym3390abjlmrz9kx07160xyrs9b1c32zy5wsldc0vqkgwz")
      iex> <<hash::binary-size(32), _::binary>> = bytes
      iex> Base.encode16(hash, case: :lower)
      "9fbf8937608d6a5efc1783859574f61d9870409fe9e74ae552208d517d397838"
  """
  @spec decode(binary()) :: {:ok, binary()} | {:error, term()}
  def decode(string) when is_binary(string) do
    chars = String.graphemes(string)

    if Enum.all?(chars, &Map.has_key?(@reverse_map, &1)) do
      # Process chars right-to-left: n=0 is the LAST char, n=1 is second-to-last, etc.
      # Each char provides 5 bits. Bit position = n * 5.
      # byte_index = bit_position / 8, bit_offset = bit_position % 8
      result =
        chars
        |> Enum.reverse()
        |> Enum.with_index()
        |> Enum.reduce(:binary.copy(<<0>>, byte_size_result(string)), fn {ch, n}, acc ->
          digit = Map.fetch!(@reverse_map, ch)
          b = n * 5
          i = div(b, 8)
          j = rem(b, 8)

          # OR the low bits into byte i
          acc = or_byte(acc, i, Bitwise.bsl(digit, j) |> Bitwise.band(0xFF))

          # If the 5-bit value spans into the next byte (j > 2, i.e., j + 5 > 8)
          if j > 3 do
            high = Bitwise.bsr(digit, 8 - j)
            or_byte(acc, i + 1, high)
          else
            acc
          end
        end)

      {:ok, result}
    else
      {:error, :invalid_character}
    end
  end

  @doc """
  Encode raw bytes to a Nix32 string.

  Processes from the end (last byte first), producing characters right-to-left.
  """
  @spec encode(binary()) :: binary()
  def encode(data) when is_binary(data) do
    # Number of 5-bit groups needed (ceil(byte_count * 8 / 5))
    num_chars = div(byte_size(data) * 8 + 4, 5)

    # Process from the end: n = num_chars-1 down to 0
    for n <- (num_chars - 1)..0//-1, into: <<>> do
      b = n * 5
      i = div(b, 8)
      j = rem(b, 8)

      byte_i = byte_at(data, i)
      byte_next = byte_at(data, i + 1)

      # Extract 5 bits: (byte_i >> j) | (byte_next << (8 - j)), masked to 5 bits
      c =
        Bitwise.bor(
          Bitwise.bsr(byte_i, j),
          Bitwise.bsl(byte_next, 8 - j)
        )
        |> Bitwise.band(0x1F)

      String.at(@alphabet, c)
    end
  end

  defp byte_at(data, i) when i < byte_size(data), do: :binary.at(data, i)
  defp byte_at(_data, _i), do: 0

  defp or_byte(binary, i, value) when i < byte_size(binary) do
    current = :binary.at(binary, i)
    new = Bitwise.bor(current, value)
    prefix = binary_part(binary, 0, i)
    suffix = binary_part(binary, i + 1, byte_size(binary) - i - 1)
    <<prefix::binary, new::8, suffix::binary>>
  end

  defp or_byte(binary, i, value) do
    # Extend binary to byte i and set value
    padding = i - byte_size(binary)
    <<binary::binary, 0::size(padding * 8), value::8>>
  end

  defp byte_size_result(string) do
    # 52 chars * 5 bits = 260 bits = 32.5 bytes → 33 bytes
    div(String.length(string) * 5 + 7, 8)
  end
end
