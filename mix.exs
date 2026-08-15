defmodule Rhizome.MixProject do
  use Mix.Project

  def project do
    [
      app: :rhizome,
      version: "0.1.0",
      elixir: "~> 1.20-rc",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Rhizome.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.8"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.7.2", override: true},
      {:msgpax, "~> 2.0"},
      {:bechamel, "~> 1.1"},
      {:nostr_ex, path: "/home/base/code/nostr-elixir/nostr_ex"}
    ]
  end
end
