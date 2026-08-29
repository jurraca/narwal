defmodule NarwalTest do
  use ExUnit.Case, async: true

  test "nix32 decode known vectors" do
    assert {:ok, bytes} = Narwal.Nix32.decode("0f3q75ym3390abjlmrz9kx07160xyrs9b1c32zy5wsldc0vqkgwz")
    <<hash::binary-size(32), _::binary>> = bytes
    assert Base.encode16(hash, case: :lower) ==
             "9fbf8937608d6a5efc1783859574f61d9870409fe9e74ae552208d517d397838"
  end

  test "manifest decode + find_link" do
    # Build a minimal BUD-16 node with Msgpax
    node = %{
      "t" => 2,
      "l" => [
        %{"h" => <<0xAB::256>>, "n" => "test.narinfo", "s" => 42, "t" => 0},
        %{"h" => <<0xCD::256>>, "n" => "nix-cache-info", "s" => 21, "t" => 0}
      ]
    }

    encoded = Msgpax.pack!(node)

    {:ok, decoded} = Narwal.Manifest.decode_node(encoded)
    assert decoded.t == 2
    assert length(decoded.l) == 2

    assert {:ok, link} = Narwal.Manifest.find_link(decoded.l, "test.narinfo")
    assert link.s == 42

    assert :not_found = Narwal.Manifest.find_link(decoded.l, "missing.narinfo")
  end
end
