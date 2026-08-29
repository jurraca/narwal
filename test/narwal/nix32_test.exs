defmodule Narwal.Nix32Test do
  use ExUnit.Case, async: true
  doctest Narwal.Nix32

  test "decode known SHA256 hashes" do
    {:ok, bytes1} = Narwal.Nix32.decode("0f3q75ym3390abjlmrz9kx07160xyrs9b1c32zy5wsldc0vqkgwz")
    <<hash1::binary-size(32), _::binary>> = bytes1
    assert Base.encode16(hash1, case: :lower) ==
             "9fbf8937608d6a5efc1783859574f61d9870409fe9e74ae552208d517d397838"

    {:ok, bytes2} = Narwal.Nix32.decode("11s5bspgkl9fx602blxbf3nsjywmgzi13qfvnl74is338grnrq74")
    <<hash2::binary-size(32), _::binary>> = bytes2
    assert Base.encode16(hash2, case: :lower) ==
             "e4e06cf34363e8480eb5dbe111e27f957ba9ed70abd32580e92ed1f9ae5e4587"
  end

  test "decode produces 33 bytes for 52-char nix32 (32 bytes + 1 partial)" do
    {:ok, bytes} = Narwal.Nix32.decode("0f3q75ym3390abjlmrz9kx07160xyrs9b1c32zy5wsldc0vqkgwz")
    assert byte_size(bytes) == 33
    <<hash::binary-size(32), _::8>> = bytes
    assert Base.encode16(hash, case: :lower) ==
             "9fbf8937608d6a5efc1783859574f61d9870409fe9e74ae552208d517d397838"
  end

  test "encode roundtrip" do
    hash = <<0x9F, 0xBF, 0x89, 0x37, 0x60, 0x8D, 0x6A, 0x5E, 0xFC, 0x17,
             0x83, 0x85, 0x95, 0x74, 0xF6, 0x1D, 0x98, 0x70, 0x40, 0x9F,
             0xE9, 0xE7, 0x4A, 0xE5, 0x52, 0x20, 0x8D, 0x51, 0x7D, 0x39,
             0x78, 0x38>>

    encoded = Narwal.Nix32.encode(hash)
    assert encoded == "0f3q75ym3390abjlmrz9kx07160xyrs9b1c32zy5wsldc0vqkgwz"
  end

  test "invalid characters return error" do
    assert {:error, :invalid_character} = Narwal.Nix32.decode("invalid_nix32_with_e_and_t")
  end
end
