# NixOS module for Bear Cub. Ships with the app repo; the consuming
# machine config pins a rev of this repo, imports this file, and sets
# option values (design §7).
{ config, lib, pkgs, ... }:

let
  cfg = config.services.bear-cub;
in
{
  options.services.bear-cub = {
    enable = lib.mkEnableOption "Bear Cub family chore + calendar dashboard";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The Bear Cub mix release package.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 4000;
      description = "HTTP port, bound on all interfaces (LAN + tailnet).";
    };

    timezone = lib.mkOption {
      type = lib.types.str;
      default = "America/Los_Angeles";
      description = "IANA timezone for routine windows and local dates.";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "localhost";
      description = "Hostname used in generated URLs (cosmetic in v1).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open the HTTP port in the firewall.";
    };

    weather = {
      latitude = lib.mkOption {
        type = lib.types.nullOr lib.types.float;
        default = null;
        description = ''
          Latitude for the kiosk weather indicator. Household data: set it
          in the private host config, never in a public repository. Weather
          is off unless both latitude and longitude are set.
        '';
      };

      longitude = lib.mkOption {
        type = lib.types.nullOr lib.types.float;
        default = null;
        description = "Longitude for the weather indicator; see latitude.";
      };

      hotAt = lib.mkOption {
        type = lib.types.int;
        default = 80;
        description = "Day's high at or above this (°F) reads as hot.";
      };

      coldBelow = lib.mkOption {
        type = lib.types.int;
        default = 60;
        description = "Day's high below this (°F) reads as cold. Must not exceed hotAt.";
      };

      precipChanceAt = lib.mkOption {
        type = lib.types.ints.between 0 100;
        default = 40;
        description = "An hourly precipitation chance (%) at or above this in the 8 AM-3 PM window counts.";
      };
    };

    countdown = {
      leadMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "The bonus countdown appears this many minutes before the cutoff. Must exceed secondsMinutes.";
      };

      secondsMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5;
        description = "At or below this many minutes left, the countdown switches to seconds.";
      };
    };

    ntfyServer = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "https://ntfy.sh";
      description = ''
        ntfy server for parent push notifications. The topic itself is
        the secret and is generated into the state directory on first
        boot (the SECRET_KEY_BASE pattern), never placed by hand; the
        admin Notifications page shows it for subscribing. Set to null
        to turn notifications off.
      '';
    };

  };

  config = lib.mkIf cfg.enable {
    systemd.services.bear-cub = {
      description = "Bear Cub family dashboard";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        PHX_SERVER = "true";
        PORT = toString cfg.port;
        PHX_HOST = cfg.host;
        BEAR_CUB_TIMEZONE = cfg.timezone;
        TZ = cfg.timezone;
        BEAR_CUB_WEATHER_HOT_AT = toString cfg.weather.hotAt;
        BEAR_CUB_WEATHER_COLD_BELOW = toString cfg.weather.coldBelow;
        BEAR_CUB_WEATHER_PRECIP_CHANCE_AT = toString cfg.weather.precipChanceAt;
        BEAR_CUB_COUNTDOWN_LEAD_MINUTES = toString cfg.countdown.leadMinutes;
        BEAR_CUB_COUNTDOWN_SECONDS_MINUTES = toString cfg.countdown.secondsMinutes;
        # Single node, no clustering: skip epmd/distribution entirely.
        RELEASE_DISTRIBUTION = "none";
        RELEASE_COOKIE = "bear-cub-no-distribution";
      } // lib.optionalAttrs (cfg.weather.latitude != null) {
        BEAR_CUB_WEATHER_LATITUDE = toString cfg.weather.latitude;
      } // lib.optionalAttrs (cfg.weather.longitude != null) {
        BEAR_CUB_WEATHER_LONGITUDE = toString cfg.weather.longitude;
      };

      # SECRET_KEY_BASE and the ntfy topic are generated into the state
      # directory on first boot: with ICS URLs living in the DB (D9), the
      # box carries zero hand-placed application secrets (design §7).
      script = ''
        if [ ! -f "$STATE_DIRECTORY/secret_key_base" ]; then
          (umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64 \
            > "$STATE_DIRECTORY/secret_key_base")
        fi
        export SECRET_KEY_BASE="$(cat "$STATE_DIRECTORY/secret_key_base")"
      '' + lib.optionalString (cfg.ntfyServer != null) ''
        if [ ! -f "$STATE_DIRECTORY/ntfy_topic" ]; then
          (umask 077; printf 'bear-cub-%s' "$(tr -dc 'a-z0-9' < /dev/urandom | head -c 32)" \
            > "$STATE_DIRECTORY/ntfy_topic")
        fi
        export BEAR_CUB_NTFY_URL="${cfg.ntfyServer}/$(cat "$STATE_DIRECTORY/ntfy_topic")"
      '' + ''
        export DATABASE_PATH="$STATE_DIRECTORY/bear_cub.db"
        export RELEASE_TMP="$STATE_DIRECTORY/tmp"
        mkdir -p "$RELEASE_TMP"
        exec ${cfg.package}/bin/bear_cub start
      '';

      serviceConfig = {
        DynamicUser = true;
        StateDirectory = "bear-cub";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
