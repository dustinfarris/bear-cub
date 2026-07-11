# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :bear_cub,
  ecto_repos: [BearCub.Repo],
  generators: [timestamp_type: :utc_datetime]

# Zone math for the configured local timezone (design §3).
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

# The kiosk must work with the WAN down (§6.1) — never phone home for
# tz updates; the compiled-in tables are refreshed by ordinary dep bumps.
config :tzdata, :autoupdate, :disabled

# Configure the endpoint
config :bear_cub, BearCubWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BearCubWeb.ErrorHTML, json: BearCubWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: BearCub.PubSub,
  live_view: [signing_salt: "kHEqohtf"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.27.2",
  bear_cub: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  bear_cub: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# In the Nix sandbox the tailwind/esbuild download tarballs are unreachable;
# nix/package.nix exports these to point the wrappers at nixpkgs binaries.
# Unset in normal dev, where the wrappers manage their own binaries.
if tailwind_path = System.get_env("MIX_TAILWIND_PATH") do
  config :tailwind, path: tailwind_path
end

if esbuild_path = System.get_env("MIX_ESBUILD_PATH") do
  config :esbuild, path: esbuild_path
end

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
