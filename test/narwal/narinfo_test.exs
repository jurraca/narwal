defmodule Narwal.NarinfoTest do
  use ExUnit.Case, async: true

  alias Narwal.Narinfo

  @hashpart "0c2a5hhq7q6wq0qry4l7g55dmvx7v8i3"

  defp narinfo_text(store_path) do
    """
    StorePath: #{store_path}
    URL: nar/0f3q75.nar.xz
    Compression: xz
    FileHash: sha256:0f3q75ym3390abjlmrz9kx07160xyrs9b1c32zy5wsldc0vqkgwz
    FileSize: 512
    NarHash: sha256:1f3q75ym3390abjlmrz9kx07160xyrs9b1c32zy5wsldc0vqkgwz
    NarSize: 4096
    """
  end

  test "parses StorePath and FileSize" do
    bytes = narinfo_text("/nix/store/#{@hashpart}-hello-2.12.1")

    assert %{store_path: "/nix/store/#{@hashpart}-hello-2.12.1", file_size: 512} =
             Narinfo.parse(bytes)
  end

  test "StorePath on the first line is found" do
    # Redundant with the above given narinfo_text starts with StorePath,
    # but makes the first-line case explicit.
    bytes = "StorePath: /nix/store/#{@hashpart}-hi\n"
    assert %{store_path: "/nix/store/#{@hashpart}-hi"} = Narinfo.parse(bytes)
  end

  test "missing fields yield nils" do
    assert %{store_path: nil, file_size: nil} = Narinfo.parse("nonsense\n")
    assert %{store_path: nil, file_size: nil} = Narinfo.parse("")
  end

  test "malformed FileSize yields nil" do
    bytes = "FileSize: not-a-number\n"
    assert %{file_size: nil} = Narinfo.parse(bytes)
  end

  test "empty field values are ignored" do
    bytes = "StorePath: \nFileSize: 10\n"
    assert %{store_path: nil} = Narinfo.parse(bytes)
  end

  test "parses References into a list" do
    bytes = """
    StorePath: /nix/store/#{@hashpart}-hello-2.12.1
    References: rkiwrqh8g6gs5rws4bf1s3mrdcs15gm9-glibc-2.42-84 yf2c1gngi2dqvgni1rgvnixxc0d8di02-gcc-15.2.0-libgcc
    """

    assert %{
             references: [
               "rkiwrqh8g6gs5rws4bf1s3mrdcs15gm9-glibc-2.42-84",
               "yf2c1gngi2dqvgni1rgvnixxc0d8di02-gcc-15.2.0-libgcc"
             ]
           } = Narinfo.parse(bytes)
  end

  test "missing References yield an empty list" do
    assert %{references: []} = Narinfo.parse(narinfo_text("/nix/store/#{@hashpart}-hello-2.12.1"))
  end

  describe "split_name/1" do
    test "splits hashpart from name" do
      assert {:ok, @hashpart, "hello-2.12.1"} = Narinfo.split_name("#{@hashpart}-hello-2.12.1")
    end

    test "keeps dashes in the name" do
      assert {:ok, @hashpart, "some-lib-1.0-dev"} =
               Narinfo.split_name("#{@hashpart}-some-lib-1.0-dev")
    end

    test "rejects names without a 32-char hashpart" do
      assert :error = Narinfo.split_name("nix-cache-info")
      assert :error = Narinfo.split_name(@hashpart)
      assert :error = Narinfo.split_name("#{String.slice(@hashpart, 0, 31)}-name")
    end

    test "rejects empty name" do
      assert :error = Narinfo.split_name("#{@hashpart}-")
    end
  end
end
