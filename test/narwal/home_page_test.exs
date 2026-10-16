defmodule Narwal.HomePageTest do
  use ExUnit.Case, async: false

  alias Narwal.HomePage

  @pubkey "aa" <> String.duplicate("bb", 31)
  @npub Bechamel.encode("npub", Base.decode16!(@pubkey, case: :mixed))
  @hashpart "0c2a5hhq7q6wq0qry4l7g55dmvx7v8i3"
  @dep_hashpart "1f3q75ym3390abjlmrz9kx07160xyrs9"

  defp put_root_and_pkgs(channel, pkgs) do
    root = %{
      root_hash_hex: String.duplicate("ab", 32),
      blossom_servers: [],
      nix_sig_keys: [],
      created_at: System.os_time(:second),
      event_id: "test",
      link_count: length(pkgs) + 1,
      total_bytes: 100,
      pkg_count: length(pkgs),
      top_pkg_count: length(pkgs)
    }

    :ets.insert(:narwal_roots, {{:root, @pubkey, channel}, root})
    :ets.insert(:narwal_roots, {{:pkgs, @pubkey, channel}, pkgs})

    on_exit(fn ->
      :ets.delete(:narwal_roots, {:root, @pubkey, channel})
      :ets.delete(:narwal_roots, {:pkgs, @pubkey, channel})
    end)
  end

  test "empty query matches nothing" do
    assert %{caches: [], pkgs: [], pkg_total: 0} = HomePage.search("")
    assert %{caches: [], pkgs: [], pkg_total: 0} = HomePage.search("   ")
  end

  test "matches package names case-insensitively across all paths" do
    put_root_and_pkgs(:default, [
      %{hashpart: @hashpart, name: "hello-2.12.1", name_lc: "hello-2.12.1", size: 512, top: true},
      %{hashpart: @dep_hashpart, name: "zstd-1.5.6", name_lc: "zstd-1.5.6", size: 256, top: false}
    ])

    assert %{caches: [], pkg_total: 1, pkgs: [pkg]} = HomePage.search("HELLO")
    assert pkg.name == "hello-2.12.1"
    assert pkg.pubkey == @pubkey
    assert pkg.channel == :default
  end

  test "matches caches by npub" do
    put_root_and_pkgs(:default, [])

    assert %{caches: [root], pkgs: [], pkg_total: 0} = HomePage.search(String.slice(@npub, 0, 12))
    assert root.pubkey == @pubkey
  end

  test "matches caches by channel" do
    put_root_and_pkgs("test", [])

    assert %{caches: [root], pkgs: [], pkg_total: 0} = HomePage.search("tes")
    assert root.channel == "test"
  end

  test "no match yields empty results" do
    put_root_and_pkgs(:default, [
      %{hashpart: @hashpart, name: "hello-2.12.1", name_lc: "hello-2.12.1", size: 512, top: true}
    ])

    assert %{caches: [], pkgs: [], pkg_total: 0} = HomePage.search("nonexistent")
  end

  test "package matches are capped but counted" do
    pkgs =
      for i <- 1..60 do
        %{
          hashpart: String.pad_leading("#{i}", 32, "0"),
          name: "pkg-#{i}",
          name_lc: "pkg-#{i}",
          size: 100,
          top: true
        }
      end

    put_root_and_pkgs(:default, pkgs)

    assert %{pkgs: shown, pkg_total: 60} = HomePage.search("pkg-")
    assert length(shown) == 50
  end
end
