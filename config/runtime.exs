import Config

require Logger

# Static defaults
priority = System.get_env("NARWAL_PRIORITY", "30") |> String.to_integer()
store_dir = System.get_env("NARWAL_STORE_DIR", "/nix/store")
port = System.get_env("NARWAL_PORT", "8090") |> String.to_integer()

# HTTP is always disabled in test (see config/test.exs); runtime.exs runs in
# every env and would otherwise override the compile-time setting.
http_enabled =
  if config_env() == :test do
    false
  else
    case System.get_env("NARWAL_HTTP_ENABLED", "true") |> String.downcase() do
      "false" -> false
      "0" -> false
      _ -> true
    end
  end

# Publisher npubs: comma-separated list.
# Falls back to singular NARWAL_PUBLISHER_NPUB for backward compat.
npubs =
  case System.get_env("NARWAL_PUBLISHER_NPUBS") do
    nil ->
      case System.get_env("NARWAL_PUBLISHER_NPUB") do
        nil -> []
        single -> [String.trim(single)]
      end

    plural ->
      plural |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

channel = System.get_env("NARWAL_CHANNEL")

relays =
  System.get_env("NARWAL_RELAYS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)

blossom_servers =
  System.get_env("NARWAL_BLOSSOM_SERVERS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)

config :narwal,
  priority: priority,
  store_dir: store_dir,
  port: port,
  http_enabled: http_enabled,
  publisher_npubs: npubs,
  channel: channel,
  relays: relays,
  blossom_servers: blossom_servers

# Startup validation
if npubs != [] and relays == [] do
  Logger.warning("NARWAL_PUBLISHER_NPUBS is set but NARWAL_RELAYS is empty — root events cannot be fetched")
end

if npubs == [] and relays != [] do
  Logger.warning("NARWAL_RELAYS is set but NARWAL_PUBLISHER_NPUBS is not — no publisher to subscribe to")
end

if blossom_servers == [] and npubs != [] do
  Logger.warning("NARWAL_BLOSSOM_SERVERS is empty — blob fetches will fail")
end

if npubs == [] and relays == [] do
  Logger.info("Narwal: no publisher configured, running in passive mode (nix-cache-info only)")
end
