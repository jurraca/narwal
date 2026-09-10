# NixOS module for Narwal — Nix binary cache proxy over Nostr + Blossom.
#
# Usage:
#   inputs.narwal.url = "path:/home/quin/projects/nix-blossom/narwal";
#   ...
#   services.narwal = {
#     enable = true;
#     openFirewall = true;
#     publisherNpubs = [ "npub1..." ];
#     relays = [ "wss://relay.example.com" ];
#     blossomServers = [ "https://blossom-1.example.com" ];
#   };

{ config, lib, pkgs, ... }:

let
  cfg = config.services.narwal;
in {
  options.services.narwal = {
    enable = lib.mkEnableOption "Narwal Nix binary cache proxy";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.narwal or (throw "narwal package not found — add the flake input to pkgs");
      defaultText = lib.literalExpression "pkgs.narwal";
      description = "The Narwal package to use.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the Narwal TCP port in the firewall.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8090;
      description = "TCP port for the HTTP server.";
    };

    priority = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Nix cache priority (lower = higher priority).";
    };

    storeDir = lib.mkOption {
      type = lib.types.str;
      default = "/nix/store";
      description = "Nix store directory advertised in nix-cache-info.";
    };

    publisherNpubs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [ "npub1..." ];
      description = "Nostr public keys of cache publishers to index.";
    };

    channel = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Named cache channel (d-tag). null = default cache (kind 17091).";
    };

    relays = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [ "wss://relay.example.com" ];
      description = "Nostr relay URLs to subscribe for root events.";
    };

    blossomServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = [ "https://blossom-1.example.com" ];
      description = "Blossom server URLs to fetch blobs from.";
    };
  };

  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts =
      lib.optional cfg.openFirewall cfg.port;

    systemd.services.narwal = {
      description = "Narwal Nix binary cache proxy";
      documentation = [ "https://github.com/your-org/nix-blossom" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      environment = {
        RHIZOME_PORT = toString cfg.port;
        RHIZOME_PRIORITY = toString cfg.priority;
        RHIZOME_STORE_DIR = cfg.storeDir;
        RHIZOME_PUBLISHER_NPUBS = lib.concatStringsSep "," cfg.publisherNpubs;
        RHIZOME_RELAYS = lib.concatStringsSep "," cfg.relays;
        RHIZOME_BLOSSOM_SERVERS = lib.concatStringsSep "," cfg.blossomServers;
        RHIZOME_HTTP_ENABLED = "true";
      } // (lib.optionalAttrs (cfg.channel != null) {
        RHIZOME_CHANNEL = cfg.channel;
      });

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} start";
        Restart = "on-failure";
        RestartSec = 5;
        DynamicUser = true;
        StateDirectory = "narwal";
        WorkingDirectory = "/var/lib/narwal";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };
  };
}
