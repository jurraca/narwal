defmodule Rhizome.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Rhizome.TreeCache, []},
      {Rhizome.Stats, []},
      {Task.Supervisor, name: Rhizome.TaskSupervisor},
      {Rhizome.RootResolver, rhizome_config()}
      | http_children()
    ]

    opts = [strategy: :one_for_one, name: Rhizome.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp http_children do
    port = Application.get_env(:rhizome, :port, 8090)

    if Application.get_env(:rhizome, :http_enabled, true) do
      [{Bandit, plug: Rhizome.Router, scheme: :http, port: port}]
    else
      []
    end
  end

  defp rhizome_config do
    %{
      npubs: Application.get_env(:rhizome, :publisher_npubs, []),
      channel: Application.get_env(:rhizome, :channel),
      relays: Application.get_env(:rhizome, :relays, []),
      blossom_servers: Application.get_env(:rhizome, :blossom_servers, []),
      priority: Application.get_env(:rhizome, :priority, 30)
    }
  end
end
