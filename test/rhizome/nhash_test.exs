defmodule Rhizome.NhashTest do
  use ExUnit.Case, async: true

  alias Rhizome.Nhash

  # Test vectors generated with Bechamel.encode("nhash", tlv)
  # to ensure cross-implementation compatibility.

  describe "decode/1 with hash-only (public content)" do
    test "decodes hash of 0x42 repeated 32 times" do
      nhash = "nhash1qqsqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsse0kdhq"

      assert {:ok, result} = Nhash.decode(nhash)
      assert result.hash == <<0x42::size(256)>>
      assert Map.has_key?(result, :key) == false
    end

    test "decodes all-zeros hash" do
      nhash = "nhash1qqsqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq2mctkg"

      assert {:ok, result} = Nhash.decode(nhash)
      assert result.hash == <<0::size(256)>>
      refute Map.has_key?(result, :key)
    end

    test "decodes known NAR hash (coreutils 9.8)" do
      nhash = "nhash1qqsfl0ufxasg66j7lstc8pv4wnmpmxrsgz07ne62u4fzpr2305uhswq47q6cg"

      expected = <<0x9F, 0xBF, 0x89, 0x37, 0x60, 0x8D, 0x6A, 0x5E,
                   0xFC, 0x17, 0x83, 0x85, 0x95, 0x74, 0xF6, 0x1D,
                   0x98, 0x70, 0x40, 0x9F, 0xE9, 0xE7, 0x4A, 0xE5,
                   0x52, 0x20, 0x8D, 0x51, 0x7D, 0x39, 0x78, 0x38>>

      assert {:ok, result} = Nhash.decode(nhash)
      assert result.hash == expected
      refute Map.has_key?(result, :key)
    end
  end

  describe "decode/1 with hash + key (encrypted content)" do
    test "decodes hash=0xAA and key=0xBB" do
      nhash = "nhash1qqsqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqp2s9yqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqtkjt8z6h"

      assert {:ok, result} = Nhash.decode(nhash)
      assert result.hash == <<0xAA::size(256)>>
      assert result.key == <<0xBB::size(256)>>
    end
  end

  describe "decode/1 with htree:// URI prefix" do
    test "strips htree:// prefix and decodes" do
      bare = "nhash1qqsqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsse0kdhq"
      uri = "htree://#{bare}"

      assert {:ok, result} = Nhash.decode(uri)
      assert result.hash == <<0x42::size(256)>>
    end

    test "handles whitespace around input" do
      bare = "nhash1qqsqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsse0kdhq"

      assert {:ok, result} = Nhash.decode("  #{bare}  ")
      assert result.hash == <<0x42::size(256)>>
    end
  end

  describe "decode/1 forward compatibility" do
    test "skips unknown TLV types and still extracts hash" do
      # TLV: type=0(hash=0x42*32) + type=99(len=3, value="abc")
      nhash = "nhash1qqsqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsnrqdskycc02c0nd"

      assert {:ok, result} = Nhash.decode(nhash)
      assert result.hash == <<0x42::size(256)>>
      refute Map.has_key?(result, :key)
    end
  end

  describe "decode/1 error cases" do
    test "returns error when hash TLV is missing (key only)" do
      nhash = "nhash1q5sqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqpwclq63hz"

      assert {:error, :missing_hash} = Nhash.decode(nhash)
    end

    test "returns error for wrong HRP" do
      # bech32 with HRP "bc" (bitcoin) instead of "nhash"
      assert {:error, {:wrong_hrp, "bc"}} = Nhash.decode("bc1qw508d6qejxtdg4y5r3zarvary0c5xw7kv8f3t4")
    end

    test "returns error for invalid bech32 (no separator)" do
      assert {:error, :no_separator} = Nhash.decode("notvalidbech32")
    end

    test "returns error for empty string" do
      assert {:error, _} = Nhash.decode("")
    end

    test "returns error for malformed TLV (truncated)" do
      # Valid bech32 with HRP "nhash" but payload is just 1 byte (type=0, no length/value)
      truncated = Bechamel.encode("nhash", <<0>>)

      assert {:error, :invalid_tlv} = Nhash.decode(truncated)
    end

    test "returns error for TLV with length exceeding data" do
      # type=0, length=32, but only 10 bytes of value
      bad_tlv = <<0, 32, "0123456789">>
      bad_nhash = Bechamel.encode("nhash", bad_tlv)

      assert {:error, :invalid_tlv} = Nhash.decode(bad_nhash)
    end
  end
end
