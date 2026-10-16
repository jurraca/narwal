defmodule Narwal.HTML do
  @moduledoc """
  Minimal EEx engine with HTML auto-escaping.

  Every `<%= %>` interpolation is escaped through
  `Plug.HTML.html_escape_to_iodata/1` unless the value is marked safe
  with `raw/1`. Control-flow blocks (`<% %>` with do/end) are not
  supported — conditionals belong in Elixir helpers that pick between
  fragments, which keeps the engine trivially auditable.
  """

  @behaviour EEx.Engine

  @doc "Mark a value as already-safe HTML, bypassing escaping."
  @spec raw(binary() | iodata()) :: {:raw, binary() | iodata()}
  def raw(bin) when is_binary(bin) or is_list(bin), do: {:raw, bin}

  @doc "Escape a value for HTML unless it was marked with `raw/1`."
  @spec escape(term()) :: iodata()
  def escape({:raw, iodata}) when is_binary(iodata) or is_list(iodata), do: iodata
  def escape(bin) when is_binary(bin), do: Plug.HTML.html_escape_to_iodata(bin)
  def escape(other), do: Plug.HTML.html_escape_to_iodata(to_string(other))

  @impl EEx.Engine
  def init(_options), do: []

  @impl EEx.Engine
  def handle_body(quoted) do
    quote do
      import Narwal.HTML, only: [raw: 1]

      Enum.reverse(unquote(quoted)) |> IO.iodata_to_binary()
    end
  end

  @impl EEx.Engine
  def handle_text(quoted, _meta, text), do: [text | quoted]

  @impl EEx.Engine
  def handle_expr(quoted, "=", expr), do: [quote(do: Narwal.HTML.escape(unquote(expr))) | quoted]

  @impl EEx.Engine
  def handle_expr(_quoted, marker, _expr) do
    raise ArgumentError, "Narwal.HTML does not support <%#{marker} %> blocks"
  end

  @impl EEx.Engine
  def handle_begin(_quoted),
    do: raise(ArgumentError, "Narwal.HTML does not support begin/end blocks")

  @impl EEx.Engine
  def handle_end(_quoted),
    do: raise(ArgumentError, "Narwal.HTML does not support begin/end blocks")
end
