import Config

# Tests exercise the router via Plug.Test and codecs directly —
# no need to bind a real HTTP port (avoids eaddrinuse across runs).
config :narwal, http_enabled: false
