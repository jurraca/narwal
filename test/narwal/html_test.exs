defmodule Narwal.HTMLTest do
  use ExUnit.Case, async: true

  defp render(template, assigns \\ []) do
    template
    |> EEx.compile_string(engine: Narwal.HTML)
    |> Code.eval_quoted(assigns, __ENV__)
    |> elem(0)
  end

  test "literal text passes through unchanged" do
    assert render("hello <b>world</b>") == "hello <b>world</b>"
  end

  test "interpolations are escaped" do
    assert render("<%= a %>", a: "<script>x</script>") ==
             "&lt;script&gt;x&lt;/script&gt;"
  end

  test "raw bypasses escaping" do
    assert render("<%= raw(a) %>", a: "<hr>") == "<hr>"
  end

  test "non-binary values are stringified then escaped" do
    assert render("<%= a %> <%= b %>", a: 512, b: {:raw, "<i>"}) == "512 <i>"
  end

  test "control-flow blocks are rejected" do
    assert_raise ArgumentError, fn ->
      render("<%= if true do %>x<% end %>")
    end
  end
end
