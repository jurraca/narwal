defmodule Narwal.ManifestTest do
  use ExUnit.Case, async: true

  test "decode_node skips malformed links instead of crashing" do
    node = %{
      "t" => 2,
      "l" => [
        %{"h" => <<0xAB::256>>, "n" => "good.narinfo", "s" => 42, "t" => 0},
        # missing "s" — malformed per HTS-01 (s is REQUIRED)
        %{"h" => <<0xCD::256>>},
        %{"h" => <<0xEF::256>>, "n" => "also-good.narinfo", "s" => 7}
      ]
    }

    encoded = Msgpax.pack!(node)
    {:ok, decoded} = Narwal.Manifest.decode_node(encoded)

    names = Enum.map(decoded.l, & &1.n)
    assert names == ["good.narinfo", "also-good.narinfo"]

    assert {:ok, link} = Narwal.Manifest.find_link(decoded.l, "good.narinfo")
    assert link.s == 42
  end

  test "decoded links are always maps with atom keys (no nils leak into node.l)" do
    # Guards the exact crash class that used to brick the RootResolver
    # GenServer: walk_dir/4 calls Map.get(link, :t, 0) and would crash with
    # BadMapError if a nil entry survived decode.
    node = %{
      "t" => 2,
      "l" => [
        %{"h" => <<0xCD::256>>},
        "not even a map"
      ]
    }

    {:ok, decoded} = Narwal.Manifest.decode_node(Msgpax.pack!(node))
    assert decoded.l == []
    assert Enum.all?(decoded.l, &is_map/1)
  end
end
