import Config

config :narwal,
  priority: 30,
  store_dir: "/nix/store"

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
