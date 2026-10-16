defmodule Narwal.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test

  test "GET /nar/<short-nix32> returns 400 instead of crashing" do
    # "0000" is all-valid nix32 chars but decodes to ~3 bytes, which used to
    # fall through the <<_::binary-size(32)>> match and raise WithClauseError.
    conn = conn(:get, "/nar/0000.nar")
    conn = Narwal.Router.call(conn, [])
    assert conn.status == 400
    assert conn.resp_body == "Invalid NAR hash"
  end

  test "GET /nar/<bad-chars> returns 400" do
    # nix32 alphabet omits e/o/u/t
    conn = conn(:get, "/nar/eeeee.nar")
    conn = Narwal.Router.call(conn, [])
    assert conn.status == 400
    assert conn.resp_body == "Invalid Nix32 hash"
  end

  test "HEAD /nar/<short-nix32> returns 404 instead of crashing" do
    conn = conn(:head, "/nar/0000.nar")
    conn = Narwal.Router.call(conn, [])
    assert conn.status == 404
  end

  test "GET /nar/<valid-hash> returns 404 when no blossom servers configured" do
    hash = "0f3q75ym3390abjlmrz9kx07160xyrs9b1c32zy5wsldc0vqkgwz"
    conn = conn(:get, "/nar/#{hash}.nar.xz")
    conn = Narwal.Router.call(conn, [])
    assert conn.status == 404
  end

  test "GET /nar/<valid-hash> 404s when no blossom server has the blob" do
    # Point at an unreachable server so the HEAD probe fails → :not_found.
    :ets.insert(:narwal_roots, {:blossom_servers, ["http://127.0.0.1:1"]})

    hash = "0f3q75ym3390abjlmrz9kx07160xyrs9b1c32zy5wsldc0vqkgwz"
    conn = conn(:get, "/nar/#{hash}.nar.xz")
    conn = Narwal.Router.call(conn, [])

    assert conn.status == 404

    :ets.delete(:narwal_roots, :blossom_servers)
  end

  test "HTTP server is not started in test env" do
    refute Application.get_env(:narwal, :http_enabled, true)
  end

  describe "home page" do
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

    test "GET / lists caches" do
      put_root_and_pkgs(:default, [%{hashpart: @hashpart, name: "hello-2.12.1", size: 512}])

      conn = conn(:get, "/")
      conn = Narwal.Router.call(conn, [])

      assert conn.status == 200
      assert conn.resp_body =~ "Narwal"
      assert conn.resp_body =~ "1 packages · 1 paths"
      assert conn.resp_body =~ "href=\"/cache/#{@npub}/default\""
    end

    test "GET /cache/<hex>/<channel> lists packages" do
      put_root_and_pkgs(:default, [%{hashpart: @hashpart, name: "hello-2.12.1", size: 512}])

      conn = conn(:get, "/cache/#{@pubkey}/default")
      conn = Narwal.Router.call(conn, [])

      assert conn.status == 200
      assert conn.resp_body =~ "hello-2.12.1"
      assert conn.resp_body =~ @hashpart
    end

    test "GET /cache/<npub>/<channel> lists packages" do
      put_root_and_pkgs(:default, [%{hashpart: @hashpart, name: "hello-2.12.1", size: 512}])

      conn = conn(:get, "/cache/#{@npub}/default")
      conn = Narwal.Router.call(conn, [])

      assert conn.status == 200
      assert conn.resp_body =~ "hello-2.12.1"
      assert conn.resp_body =~ @hashpart
    end

    test "GET /cache/<pubkey>/<channel> filters by q" do
      put_root_and_pkgs(:default, [
        %{hashpart: @hashpart, name: "hello-2.12.1", size: 512},
        %{
          hashpart: "1f3q75ym3390abjlmrz9kx07160xyrs9b1c32zy5wsldc0vqkgwz",
          name: "zstd-1.5.6",
          size: 256
        }
      ])

      conn = conn(:get, "/cache/#{@pubkey}/default?q=hello")
      conn = Narwal.Router.call(conn, [])

      assert conn.status == 200
      assert conn.resp_body =~ "hello-2.12.1"
      refute conn.resp_body =~ "zstd-1.5.6"
    end

    test "GET /cache/<pubkey>/<channel> for unknown cache says so" do
      conn = conn(:get, "/cache/#{@pubkey}/default")
      conn = Narwal.Router.call(conn, [])

      assert conn.status == 200
      assert conn.resp_body =~ "Unknown cache"
    end

    test "GET /cache/<npub>/<channel> defaults to top-level packages" do
      put_root_and_pkgs(:default, [
        %{hashpart: @hashpart, name: "hello-2.12.1", size: 512, top: true},
        %{hashpart: @dep_hashpart, name: "zstd-1.5.6", size: 256, top: false}
      ])

      conn = conn(:get, "/cache/#{@npub}/default")
      conn = Narwal.Router.call(conn, [])

      assert conn.status == 200
      assert conn.resp_body =~ "hello-2.12.1"
      refute conn.resp_body =~ "zstd-1.5.6"
      assert conn.resp_body =~ "show all 2 packages"
    end

    test "GET /cache/<npub>/<channel>?scope=all lists dependencies too" do
      put_root_and_pkgs(:default, [
        %{hashpart: @hashpart, name: "hello-2.12.1", size: 512, top: true},
        %{hashpart: @dep_hashpart, name: "zstd-1.5.6", size: 256, top: false}
      ])

      conn = conn(:get, "/cache/#{@npub}/default?scope=all")
      conn = Narwal.Router.call(conn, [])

      assert conn.status == 200
      assert conn.resp_body =~ "hello-2.12.1"
      assert conn.resp_body =~ "zstd-1.5.6"
      assert conn.resp_body =~ "top-level only"
    end
  end
end
