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
        # Single node, no clustering: skip epmd/distribution entirely.
        RELEASE_DISTRIBUTION = "none";
        RELEASE_COOKIE = "bear-cub-no-distribution";
      };

      # SECRET_KEY_BASE is generated into the state directory on first
      # boot: with ICS URLs living in the DB (D9), the box carries zero
      # hand-placed application secrets (design §7).
      script = ''
        if [ ! -f "$STATE_DIRECTORY/secret_key_base" ]; then
          (umask 077; tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64 \
            > "$STATE_DIRECTORY/secret_key_base")
        fi
        export SECRET_KEY_BASE="$(cat "$STATE_DIRECTORY/secret_key_base")"
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
