import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :bear_cub, BearCub.Repo,
  database: Path.expand("../bear_cub_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :bear_cub, BearCubWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "023AFc4+cMFGvf3L3vMUUVr3aZQeI8XEWUOTYHCX3GNDDom3LyEd0tLcOwGYV1b0",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Tests drive BearCub.Calendars.Refresher directly rather than starting the
# supervised process, and stub its Req calls instead of hitting the network.
config :bear_cub, :calendar_refresher_enabled, false
config :bear_cub, :calendars_req_options, plug: {Req.Test, BearCub.Calendars.Refresher}
