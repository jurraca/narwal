defmodule Narwal.RootResolverTest do
  use ExUnit.Case, async: true

  alias Narwal.{RootResolver, TreeCache}

  @hashpart "0c2a5hhq7q6wq0qry4l7g55dmvx7v8i3"

  defp put_node(node) do
    hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    TreeCache.insert_node(hex, node)
    hex
  end

  defp blob_link(name, size, t \\ 0) do
    %{h: :crypto.strong_rand_bytes(32), n: name, s: size, t: t}
  end

  defp put_narinfo(name, narinfo_text) do
    hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    TreeCache.insert_narinfo(hex, narinfo_text)
    hex
  end

  defp narinfo_text(store_path, references \\ []) do
    refs = if references == [], do: "", else: "References: #{Enum.join(references, " ")}\n"
    "StorePath: #{store_path}\n#{refs}FileSize: 512\n"
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

    {count, bytes, entries, leaves} = RootResolver.walk_dir_collect(root_hex, [], MapSet.new())

    assert count == 3
    assert bytes == 60

    names = entries |> Enum.map(fn {{:narinfo, n}, _} -> n end) |> Enum.sort()
    assert names == ["a.narinfo", "b.narinfo", "c.narinfo"]

    assert Enum.all?(entries, fn {{:narinfo, _name}, {hash_hex, servers}} ->
             is_binary(hash_hex) and servers == []
           end)

    assert Enum.map(leaves, & &1.name) |> Enum.sort() ==
             ["a.narinfo", "b.narinfo", "c.narinfo"]
  end

  test "walk_dir_collect skips links without names (chunks, not narinfo entries)" do
    node = %{t: 2, l: [blob_link(nil, 10), blob_link("a.narinfo", 20)]}
    hex = put_node(node)

    {count, bytes, entries, _leaves} = RootResolver.walk_dir_collect(hex, [], MapSet.new())

    assert count == 1
    assert bytes == 20
    assert [{{:narinfo, "a.narinfo"}, _}] = entries
  end

  test "walk_dir_collect survives a node linking to itself" do
    h = :crypto.strong_rand_bytes(32)
    hex = Base.encode16(h, case: :lower)
    TreeCache.insert_node(hex, %{t: 2, l: [%{h: h, n: nil, s: 0, t: 2}]})

    assert {0, 0, [], []} = RootResolver.walk_dir_collect(hex, [], MapSet.new())
  end

  test "walk_dir_collect returns empty for unknown node hash" do
    hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    assert {0, 0, [], []} = RootResolver.walk_dir_collect(hex, [], MapSet.new())
  end

  test "enrich_leaves extracts package names from narinfo blobs" do
    hello_hex = put_narinfo("hello", narinfo_text("/nix/store/#{@hashpart}-hello-2.12.1"))
    other_hashpart = "1f3q75ym3390abjlmrz9kx07160xyrs9"
    zstd_hex = put_narinfo("zstd", narinfo_text("/nix/store/#{other_hashpart}-zstd-1.5.6"))

    leaves = [
      %{name: "#{@hashpart}.narinfo", hash_hex: hello_hex, size: 100, servers: []},
      %{name: "#{other_hashpart}.narinfo", hash_hex: zstd_hex, size: 120, servers: []}
    ]

    assert RootResolver.enrich_leaves(leaves) == [
             %{
               hashpart: @hashpart,
               name: "hello-2.12.1",
               name_lc: "hello-2.12.1",
               size: 512,
               top: true
             },
             %{
               hashpart: other_hashpart,
               name: "zstd-1.5.6",
               name_lc: "zstd-1.5.6",
               size: 512,
               top: true
             }
           ]
  end

  test "enrich_leaves marks referenced packages as non-top-level" do
    dep_hp = "1f3q75ym3390abjlmrz9kx07160xyrs9"
    # "garbage" has no 32-char hashpart and must be ignored, not crash.
    top_hex =
      put_narinfo(
        "hello",
        narinfo_text("/nix/store/#{@hashpart}-hello-2.12.1", ["#{dep_hp}-zstd-1.5.6", "garbage"])
      )

    dep_hex = put_narinfo("dep", narinfo_text("/nix/store/#{dep_hp}-zstd-1.5.6"))

    leaves = [
      %{name: "#{@hashpart}.narinfo", hash_hex: top_hex, size: 100, servers: []},
      %{name: "#{dep_hp}.narinfo", hash_hex: dep_hex, size: 120, servers: []}
    ]

    assert RootResolver.enrich_leaves(leaves) == [
             %{
               hashpart: @hashpart,
               name: "hello-2.12.1",
               name_lc: "hello-2.12.1",
               size: 512,
               top: true
             },
             %{hashpart: dep_hp, name: "zstd-1.5.6", name_lc: "zstd-1.5.6", size: 512, top: false}
           ]
  end

  test "enrich_leaves falls back to hashpart when the narinfo blob is unavailable" do
    # No narinfo blob cached, no servers to fetch from → unknown name.
    leaves = [%{name: "#{@hashpart}.narinfo", hash_hex: "deadbeef", size: 100, servers: []}]

    assert RootResolver.enrich_leaves(leaves) == [
             %{hashpart: @hashpart, name: nil, name_lc: @hashpart, size: nil, top: true}
           ]
  end

  test "enrich_leaves drops non-narinfo entries like nix-cache-info" do
    # Cache a blob for nix-cache-info too: it parses to no StorePath, but
    # even the no-blob path must skip it (name lacks the .narinfo suffix).
    nci_hex = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    TreeCache.insert_narinfo(nci_hex, "StoreDir: /nix/store\n")

    hello_hex = put_narinfo("hello", narinfo_text("/nix/store/#{@hashpart}-hello-2.12.1"))

    leaves = [
      %{name: "nix-cache-info", hash_hex: nci_hex, size: 42, servers: []},
      %{name: "#{@hashpart}.narinfo", hash_hex: hello_hex, size: 100, servers: []}
    ]

    assert RootResolver.enrich_leaves(leaves) == [
             %{
               hashpart: @hashpart,
               name: "hello-2.12.1",
               name_lc: "hello-2.12.1",
               size: 512,
               top: true
             }
           ]
  end

  test "enrich_leaves returns [] for no leaves" do
    assert RootResolver.enrich_leaves([]) == []
  end

  defp hex_to_bin(hex) do
    {:ok, bin} = Base.decode16(hex, case: :lower)
    bin
  end
end
