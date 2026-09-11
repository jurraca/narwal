defmodule Narwal.MixProject do
  use Mix.Project

  def project do
    [
      app: :narwal,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        narwal: [
          include_executables_for: [:unix],
          applications: [runtime_tools: :permanent]
        ]
      ]
    ]
  end

  def application do
    [
      mod: {Narwal.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.12.5"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.7.2", override: true},
      {:msgpax, "~> 2.0"},
      {:bechamel, "~> 1.1"},
      {:nostr_ex, github: "jurraca/nostr_ex"},
      # dev deps
      {:deps_nix, "~> 3.1.1", only: :dev}
    ]
  end
end
