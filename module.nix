# Unified managed service framework
#
# Each managedServices.<name> declaration generates:
#   - proxy.services.<name> (if domain is set)
#   - users/groups (if user is set)
#   - systemd.tmpfiles.rules (if stateDir is set)
#   - networking.firewall ports (if openPorts/openUDPPorts is set)
#   - systemd.services.<serviceName> (if service is set)
#   - deployment assertion (if deployment.slotPath or .package options exist)
#   - mqtt.users.<mqtt.user>.acl accumulation (if mqtt is set)
#
# Usage in a service module:
#   managedServices.autohome = {
#     description = "Home automation";
#     domain = cfg.domain;
#     port = cfg.webPort;
#     deployment = { inherit (cfg) slotPath package; binName = "autohome-server"; };
#     hardening = "standard";
#     user = "autohome";
#     stateDir = "/var/lib/autohome";
#     openPorts = [cfg.webPort];
#     mqtt = { user = "automation"; acl = ["readwrite home/#"]; };
#     service = {
#       environment = { NODE_ENV = "production"; };
#       script = "exec ${config.managedServices.autohome.binaryPath}";
#     };
#   };
{
  config,
  lib,
  ...
}: let
  managedServiceModule = lib.types.submodule ({
    name,
    config,
    ...
  }: {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether this managed service is active";
      };

      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };

      # ── Proxy ──────────────────────────────────────────────────
      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Domain for reverse proxy. null = no proxy.";
      };

      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "Service port (auto-detected for common services if null)";
      };

      target = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Proxy target URL (for containers). Overrides port.";
      };

      locations = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
        default = null;
        description = "Custom NGINX locations (for CGI). Overrides port.";
      };

      publicAccess = lib.mkOption {
        type = lib.types.bool;
        default = false;
      };

      # ── Deployment ─────────────────────────────────────────────
      deployment = {
        slotPath = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "App-slot symlink path";
        };

        package = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = null;
          description = "Package providing the binary";
        };

        binName = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Binary name inside bin/";
        };
      };

      # ── Computed (read-only) ───────────────────────────────────
      binaryPath = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default =
          if config.deployment.slotPath != null
          then "${config.deployment.slotPath}/bin/${config.deployment.binName}"
          else if config.deployment.package != null
          then "${config.deployment.package}/bin/${config.deployment.binName}"
          else throw "managedServices.${name}: either deployment.slotPath or deployment.package must be set";
      };

      hardeningConfig = lib.mkOption {
        type = lib.types.attrs;
        readOnly = true;
        default = let
          p = config.hardening;
        in
          if p == "strict"
          then {
            DynamicUser = true;
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectControlGroups = true;
            RestrictNamespaces = true;
            RestrictSUIDSGID = true;
          }
          else if p == "standard"
          then
            {
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
            }
            // lib.optionalAttrs (config.stateDir != null) {
              ReadWritePaths = [config.stateDir];
            }
          else {};
      };

      # ── Service identity ───────────────────────────────────────
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "System user. null = DynamicUser (with strict hardening).";
      };

      group = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = config.user;
        description = "System group. Defaults to user name.";
      };

      stateDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Persistent state directory";
      };

      # ── Security ───────────────────────────────────────────────
      hardening = lib.mkOption {
        type = lib.types.enum ["none" "standard" "strict"];
        default = "standard";
      };

      openPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [];
      };

      openUDPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [];
      };

      # ── MQTT ───────────────────────────────────────────────────
      mqtt = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            user = lib.mkOption {
              type = lib.types.str;
              description = "MQTT user name (shared across services)";
            };
            acl = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "ACL rules for this service's MQTT access";
            };
          };
        });
        default = null;
      };

      # ── Systemd service ────────────────────────────────────────
      serviceName = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Override systemd service name";
      };

      service = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        default = null;
        description = ''
          Partial systemd service definition. If set, the framework creates
          systemd.services.<serviceName> by merging framework defaults with this.
          If null, no systemd service is created (for wrapper modules).
        '';
      };
    };
  });

  # Collect all enabled managed services
  enabledServices = lib.filterAttrs (_: svc: svc.enable) config.managedServices;

  # Collect MQTT ACL entries grouped by user
  mqttAcls = let
    servicesWithMqtt = lib.filterAttrs (_: svc: svc.mqtt != null) enabledServices;
    entries = lib.mapAttrsToList (_: svc: {
      inherit (svc.mqtt) user acl;
    }) servicesWithMqtt;
  in
    lib.foldl' (
      acc: entry:
        acc
        // {
          ${entry.user} =
            (acc.${entry.user} or [])
            ++ entry.acl;
        }
    ) {}
    entries;
in {
  options.managedServices = lib.mkOption {
    type = lib.types.attrsOf managedServiceModule;
    default = {};
    description = "Managed service declarations. Each generates proxy, users, hardening, and service infrastructure.";
  };

  config = lib.mkIf (enabledServices != {}) (lib.mkMerge (
    # Per-service config generation
    (lib.mapAttrsToList (
        name: svc:
          lib.mkMerge [
            # ── Proxy registration ───────────────────────────────
            (lib.mkIf (svc.domain != null) {
              proxy.services.${name} =
                {
                  enable = true;
                  inherit (svc) domain;
                }
                // lib.optionalAttrs (svc.port != null) {inherit (svc) port;}
                // lib.optionalAttrs (svc.target != null) {inherit (svc) target;}
                // lib.optionalAttrs (svc.locations != null) {inherit (svc) locations;}
                // lib.optionalAttrs (svc.description != null) {inherit (svc) description;}
                // lib.optionalAttrs svc.publicAccess {inherit (svc) publicAccess;};
            })

            # ── Users and groups ─────────────────────────────────
            (lib.mkIf (svc.user != null) {
              users.users.${svc.user} = {
                isSystemUser = true;
                group = svc.group;
                home = lib.mkIf (svc.stateDir != null) svc.stateDir;
                createHome = lib.mkIf (svc.stateDir != null) true;
              };
              users.groups.${svc.group} = {};
            })

            # ── State directory ──────────────────────────────────
            (lib.mkIf (svc.stateDir != null && svc.user != null) {
              systemd.tmpfiles.rules = [
                "d ${svc.stateDir} 0750 ${svc.user} ${svc.group} -"
              ];
            })

            # ── Firewall ─────────────────────────────────────────
            (lib.mkIf (svc.openPorts != []) {
              networking.firewall.allowedTCPPorts = svc.openPorts;
            })

            (lib.mkIf (svc.openUDPPorts != []) {
              networking.firewall.allowedUDPPorts = svc.openUDPPorts;
            })

            # ── Deployment assertion ─────────────────────────────
            (lib.mkIf (svc.deployment.slotPath != null || svc.deployment.package != null || svc.service != null) {
              assertions = [
                {
                  assertion = svc.deployment.slotPath != null || svc.deployment.package != null;
                  message = "managedServices.${name}: either deployment.slotPath or deployment.package must be set";
                }
              ];
            })

            # ── Systemd service ──────────────────────────────────
            (lib.mkIf (svc.service != null) {
              systemd.services.${svc.serviceName} = lib.mkMerge [
                # Framework defaults
                {
                  wantedBy = ["multi-user.target"];
                  after = ["network.target"];
                  serviceConfig =
                    {
                      Type = "simple";
                      Restart = "always";
                      RestartSec = 10;
                    }
                    // svc.hardeningConfig
                    // lib.optionalAttrs (svc.user != null) {
                      User = svc.user;
                      Group = svc.group;
                    }
                    // lib.optionalAttrs (svc.service.script or null == null && svc.service.serviceConfig.ExecStart or null == null) {
                      ExecStart = svc.binaryPath;
                    };
                }
                # User overrides (merged on top of defaults)
                (builtins.removeAttrs svc.service ["script"])
                # Script handled separately (not in serviceConfig)
                (lib.mkIf (svc.service.script or null != null) {
                  inherit (svc.service) script;
                })
              ];
            })
          ]
      )
      enabledServices)
    # ── MQTT ACL accumulation ────────────────────────────────
    ++ [
      {
        mqtt.users =
          lib.mapAttrs (_user: acls: {
            acl = acls;
          })
          mqttAcls;
      }
    ]
  ));
}
