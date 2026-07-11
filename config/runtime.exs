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

# Routine active windows (D1/D8, design §3): app config, env-overridable,
# HH:MM-HH:MM local wall-clock, e.g. BEAR_CUB_MORNING_WINDOW=05:00-17:00.
# Windows must not span midnight: start must be before end, checked at boot.
parse_window! = fn var, default ->
  {starts, ends} =
    case System.get_env(var) do
      nil ->
        default

      value ->
        case String.split(value, "-") do
          [starts, ends] ->
            {Time.from_iso8601!(starts <> ":00"), Time.from_iso8601!(ends <> ":00")}

          _ ->
            raise "#{var} must look like 05:00-17:00, got: #{inspect(value)}"
        end
    end

  if Time.compare(starts, ends) != :lt do
    raise "#{var} start must be before end (windows must not span midnight), " <>
            "got: #{starts}-#{ends}"
  end

  {starts, ends}
end

config :bear_cub, :routine_windows,
  morning: parse_window!.("BEAR_CUB_MORNING_WINDOW", {~T[05:00:00], ~T[17:00:00]}),
  evening: parse_window!.("BEAR_CUB_EVENING_WINDOW", {~T[17:00:00], ~T[23:00:00]})

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
