defmodule Narwal.IndexTest do
  use ExUnit.Case, async: false

  alias Narwal.Index

  @pubkey "aa" <> String.duplicate("bb", 31)

  test "roots/0 returns roots with pubkey and channel merged in" do
    :ets.insert(:narwal_roots, {{:root, @pubkey, :default}, %{created_at: 1, event_id: "t"}})
    on_exit(fn -> :ets.delete(:narwal_roots, {:root, @pubkey, :default}) end)

    assert [%{pubkey: @pubkey, channel: :default, event_id: "t"}] = Index.roots()
  end

  test "pkgs/2 returns the package list for one cache" do
    pkgs = [%{hashpart: "h", name: "hello-2.12.1", size: 512, top: true}]
    :ets.insert(:narwal_roots, {{:pkgs, @pubkey, "test"}, pkgs})
    on_exit(fn -> :ets.delete(:narwal_roots, {:pkgs, @pubkey, "test"}) end)

    assert Index.pkgs(@pubkey, "test") == pkgs
  end

  test "pkgs/2 for an unknown cache returns []" do
    assert Index.pkgs(@pubkey, "nonexistent") == []
  end
end
