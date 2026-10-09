import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/bear_cub start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :bear_cub, BearCubWeb.Endpoint, server: true
end

# One configured timezone for all "today" and window decisions (design §3).
config :bear_cub, :timezone, System.get_env("BEAR_CUB_TIMEZONE", "America/Los_Angeles")

# Weather indicator (SC-2, D139): coordinates and thresholds set once in the
# NixOS module. Unset coordinates turn weather off; invalid thresholds raise
# here, so the app refuses to start. Coordinates are household data: never in
# git, never logged.
for {key, value} <- BearCub.Weather.Config.from_env(System.get_env()) do
  config :bear_cub, :"weather_#{key}", value
end

# Bonus countdown (SC-1, SC-2, D147): lead time and seconds switch, in minutes,
# set once in the NixOS module. Invalid values raise here, so the app refuses
# to start.
config :bear_cub, :bonus_countdown, BearCub.Countdown.config_from_env(System.get_env())

# Calendar refresh pipeline (design §6): fetch interval within the ~15-minute
# freshness target (FR-18), and the staleness threshold (FR-20, ~2h proposed).
config :bear_cub,
       :calendar_refresh_interval_ms,
       :timer.minutes(
         String.to_integer(System.get_env("BEAR_CUB_CALENDAR_REFRESH_MINUTES", "10"))
       )

config :bear_cub,
       :calendar_staleness_threshold_ms,
       :timer.hours(String.to_integer(System.get_env("BEAR_CUB_CALENDAR_STALENESS_HOURS", "2")))

# Parent push notifications over ntfy (backlog 2026-07-24 ruling): the
# full topic URL, e.g. https://ntfy.sh/<long-random-topic>. Unset means
# notifications are off. The URL is the secret — it gets the ICS-URL
# treatment (never in git, never logged); on the server the NixOS module
# generates the topic into the state directory on first boot, the same
# way it makes SECRET_KEY_BASE, and the admin Notifications page shows it.
#
# Not in test: .envrc exports a dev topic, and a set URL there makes every
# chore completion spawn a push task with no Req.Test stub. Tests that
# want pushes set the URL themselves.
if config_env() != :test do
  config :bear_cub, :ntfy_url, System.get_env("BEAR_CUB_NTFY_URL")
end

port = String.to_integer(System.get_env("PORT", "4000"))

# test.exs pins its own port; this line must not override it (Phase 2 review)
if config_env() != :test do
  config :bear_cub, BearCubWeb.Endpoint, http: [port: port]
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :bear_cub, BearCubWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/bear_cub_web/router\.ex$"E,
        ~r"lib/bear_cub_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /var/lib/bear-cub/bear_cub.db
      """

  config :bear_cub, BearCub.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"

  # HTTP only, bound on all interfaces (LAN + tailnet). The network is the
  # trust boundary (D5); the kiosk targets the raw LAN IP while parents use
  # the Tailscale name, so origin pinning would only fight legitimate
  # clients (design §7).
  config :bear_cub, BearCubWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [ip: {0, 0, 0, 0}, port: port],
    check_origin: false,
    secret_key_base: secret_key_base
end
