defmodule Narwal.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Narwal.TreeCache, []},
      {Narwal.Stats, []},
      {Task.Supervisor, name: Narwal.TaskSupervisor},
      {Narwal.RootResolver, narwal_config()}
      | http_children()
    ]

    opts = [strategy: :one_for_one, name: Narwal.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp http_children do
    port = Application.get_env(:narwal, :port, 8090)

    if Application.get_env(:narwal, :http_enabled, true) do
      [{Bandit, plug: Narwal.Router, scheme: :http, port: port}]
    else
      []
    end
  end

  defp narwal_config do
    %{
      npubs: Application.get_env(:narwal, :publisher_npubs, []),
      channel: Application.get_env(:narwal, :channel),
      relays: Application.get_env(:narwal, :relays, []),
      blossom_servers: Application.get_env(:narwal, :blossom_servers, []),
      priority: Application.get_env(:narwal, :priority, 30)
    }
  end
end
