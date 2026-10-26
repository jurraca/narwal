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
end
