defmodule Rhizome.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test

  test "GET /nar/<short-nix32> returns 400 instead of crashing" do
    # "0000" is all-valid nix32 chars but decodes to ~3 bytes, which used to
    # fall through the <<_::binary-size(32)>> match and raise WithClauseError.
    conn = conn(:get, "/nar/0000.nar")
    conn = Rhizome.Router.call(conn, [])
    assert conn.status == 400
    assert conn.resp_body == "Invalid NAR hash"
  end

  test "GET /nar/<bad-chars> returns 400" do
    # nix32 alphabet omits e/o/u/t
    conn = conn(:get, "/nar/eeeee.nar")
    conn = Rhizome.Router.call(conn, [])
    assert conn.status == 400
    assert conn.resp_body == "Invalid Nix32 hash"
  end

  test "HEAD /nar/<short-nix32> returns 404 instead of crashing" do
    conn = conn(:head, "/nar/0000.nar")
    conn = Rhizome.Router.call(conn, [])
    assert conn.status == 404
  end

  test "HTTP server is not started in test env" do
    refute Application.get_env(:rhizome, :http_enabled, true)
  end
end
