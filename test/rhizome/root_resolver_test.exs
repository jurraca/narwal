defmodule Rhizome.RootResolverTest do
  use ExUnit.Case, async: true

  alias Rhizome.{RootResolver, TreeCache}

  defp put_node(node) do
    hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    TreeCache.insert_node(hex, node)
    hex
  end

  defp blob_link(name, size, t \\ 0) do
    %{h: :crypto.strong_rand_bytes(32), n: name, s: size, t: t}
  end

  test "walk_dir_collect flattens chunked directories" do
    leaf1 = %{t: 2, l: [blob_link("a.narinfo", 10), blob_link("b.narinfo", 20)]}
    leaf1_hex = put_node(leaf1)

    leaf2 = %{t: 2, l: [blob_link("c.narinfo", 30)]}
    leaf2_hex = put_node(leaf2)

    root = %{
      t: 2,
      l: [
        %{h: hex_to_bin(leaf1_hex), n: nil, s: 30, t: 2},
        %{h: hex_to_bin(leaf2_hex), n: nil, s: 30, t: 2}
      ]
    }

    root_hex = put_node(root)

    {count, bytes, entries} = RootResolver.walk_dir_collect(root_hex, [], MapSet.new())

    assert count == 3
    assert bytes == 60

    names = entries |> Enum.map(fn {{:narinfo, n}, _} -> n end) |> Enum.sort()
    assert names == ["a.narinfo", "b.narinfo", "c.narinfo"]

    assert Enum.all?(entries, fn {{:narinfo, _name}, {hash_hex, servers}} ->
             is_binary(hash_hex) and servers == []
           end)
  end

  test "walk_dir_collect skips links without names (chunks, not narinfo entries)" do
    node = %{t: 2, l: [blob_link(nil, 10), blob_link("a.narinfo", 20)]}
    hex = put_node(node)

    {count, bytes, entries} = RootResolver.walk_dir_collect(hex, [], MapSet.new())

    assert count == 1
    assert bytes == 20
    assert [{{:narinfo, "a.narinfo"}, _}] = entries
  end

  test "walk_dir_collect survives a node linking to itself" do
    h = :crypto.strong_rand_bytes(32)
    hex = Base.encode16(h, case: :lower)
    TreeCache.insert_node(hex, %{t: 2, l: [%{h: h, n: nil, s: 0, t: 2}]})

    assert {0, 0, []} = RootResolver.walk_dir_collect(hex, [], MapSet.new())
  end

  test "walk_dir_collect returns empty for unknown node hash" do
    hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    assert {0, 0, []} = RootResolver.walk_dir_collect(hex, [], MapSet.new())
  end

  defp hex_to_bin(hex) do
    {:ok, bin} = Base.decode16(hex, case: :lower)
    bin
  end
end
