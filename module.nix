# Unified managed service framework
#
# Each managedServices.<name> declaration generates:
#   - proxy.services.<name> (if domain is set AND nix-auto-proxy is available)
#   - users/groups (if user is set)
#   - systemd.tmpfiles.rules (if stateDir is set)
#   - networking.firewall ports (if openPorts/openUDPPorts is set)
#   - systemd.services.<serviceName> (if service is set)
#   - deployment assertion (only when ExecStart would be auto-generated)
#   - mqtt.users.<mqtt.user>.acl accumulation (if mqtt is set)
#
# Usage in a service module:
#   managedServices.myapp = {
#     description = "My application";
#     domain = cfg.domain;
#     port = cfg.webPort;
#     deployment = { inherit (cfg) slotPath package; binName = "myapp-server"; };
#     hardening = "standard";
#     user = "myapp";
#     stateDir = "/var/lib/myapp";
#     openPorts = [cfg.webPort];
#     mqtt = { user = "myapp"; acl = ["readwrite myapp/#"]; };
#     service = {
#       environment = { NODE_ENV = "production"; };
#       script = "exec ${config.managedServices.myapp.binaryPath}";
#     };
#   };
#
# Peer dependencies (optional):
#   - nix-auto-proxy: if imported, proxy.services entries are auto-generated from domain
#   - Without it, set domain for metadata only; wire your own reverse proxy
{
  config,
  lib,
  options,
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
        description = "Whether this managed service is active.";
      };

      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Human-readable description of this service.";
      };

      # ── Proxy ──────────────────────────────────────────────────
      domain = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Domain for reverse proxy. null = no proxy.
          Requires nix-auto-proxy for automatic proxy.services generation.
        '';
      };

      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = "HTTP port the service listens on. Used for proxy target.";
      };

      target = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Explicit proxy target URL (e.g. for containers). Overrides port.";
      };

      locations = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.anything);
        default = null;
        description = "Custom NGINX location blocks (e.g. for FastCGI). Overrides port-based proxy.";
      };

      publicAccess = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the service is publicly accessible (passed to proxy).";
      };

      # ── Deployment ─────────────────────────────────────────────
      deployment = {
        slotPath = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Path to a symlink-based deployment slot (e.g. /srv/apps/myapp/current).";
        };

        package = lib.mkOption {
          type = lib.types.nullOr lib.types.package;
          default = null;
          description = "Nix package providing the service binary.";
        };

        binName = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Binary name inside the package's bin/ directory.";
        };
      };

      # ── Computed (read-only) ───────────────────────────────────
      binaryPath = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        readOnly = true;
        default =
          if config.deployment.slotPath != null
          then "${config.deployment.slotPath}/bin/${config.deployment.binName}"
          else if config.deployment.package != null
          then "${config.deployment.package}/bin/${config.deployment.binName}"
          else null;
        description = ''
          Resolved path to the service binary. Computed from deployment.slotPath
          or deployment.package. null if neither is set.
        '';
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
        description = "Computed systemd hardening directives based on the hardening preset.";
      };

      # ── Service identity ───────────────────────────────────────
      user = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "System user to create and run the service as. null = no user created (use DynamicUser or existing user).";
      };

      group = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = config.user;
        description = "System group. Defaults to the user name.";
      };

      stateDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Persistent state directory. Created via tmpfiles with proper ownership.";
      };

      # ── Security ───────────────────────────────────────────────
      hardening = lib.mkOption {
        type = lib.types.enum ["none" "standard" "strict"];
        default = "standard";
        description = ''
          Systemd hardening preset:
          - "none": no hardening directives
          - "standard": NoNewPrivileges, PrivateTmp, ProtectSystem=strict, ProtectHome
          - "strict": all of standard plus DynamicUser, kernel/cgroup protection, namespace restrictions
        '';
      };

      openPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [];
        description = "TCP ports to open in the firewall.";
      };

      openUDPPorts = lib.mkOption {
        type = lib.types.listOf lib.types.port;
        default = [];
        description = "UDP ports to open in the firewall.";
      };

      # ── MQTT ───────────────────────────────────────────────────
      mqtt = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            user = lib.mkOption {
              type = lib.types.str;
              description = "MQTT username. Multiple services can share a user; their ACLs are merged.";
            };
            acl = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "ACL rules for this service (e.g. 'readwrite myapp/#').";
            };
          };
        });
        default = null;
        description = "MQTT client declaration. ACLs are accumulated per-user across all services.";
      };

      # ── Systemd service ────────────────────────────────────────
      serviceName = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "Systemd service unit name. Defaults to the managed service name.";
      };

      service = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        default = null;
        description = ''
          Partial systemd service definition, merged with framework defaults.
          If set, the framework creates systemd.services.<serviceName>.
          If null, no systemd service is created (useful for wrapper modules
          around upstream NixOS services like jellyfin or forgejo).

          Framework defaults: Type=simple, Restart=always, RestartSec=10,
          wantedBy=multi-user.target, after=network.target, plus hardening
          config. ExecStart is auto-set to binaryPath unless script or
          explicit ExecStart is provided.
        '';
      };
    };
  });

  # Collect all enabled managed services
  enabledServices = lib.filterAttrs (_: svc: svc.enable) config.managedServices;

  # Whether nix-auto-proxy is available (proxy.services option exists)
  hasProxy = options ? proxy && options.proxy ? services;

  # Whether a service needs auto-generated ExecStart (no script, no explicit ExecStart)
  needsExecStart = svc:
    svc.service != null
    && (svc.service.script or null) == null
    && (svc.service.serviceConfig.ExecStart or null) == null;

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
    description = ''
      Managed service declarations. Each entry generates NixOS infrastructure:
      reverse proxy, system users, state directories, firewall rules, systemd
      services, and MQTT ACL entries — all from a single declarative block.
    '';
  };

  config = lib.mkIf (enabledServices != {}) (lib.mkMerge (
    # Per-service config generation
    (lib.mapAttrsToList (
        name: svc:
          lib.mkMerge [
            # ── Proxy registration (only if nix-auto-proxy is available) ──
            (lib.mkIf (svc.domain != null && hasProxy) {
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

            # ── Deployment assertion (only when ExecStart would be auto-generated) ──
            (lib.mkIf (needsExecStart svc) {
              assertions = [
                {
                  assertion = svc.binaryPath != null;
                  message = "managedServices.${name}: either deployment.slotPath or deployment.package must be set (needed for auto-generated ExecStart)";
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
                    // lib.optionalAttrs (needsExecStart svc && svc.binaryPath != null) {
                      ExecStart = svc.binaryPath;
                    };
                }
                # User overrides (merged on top of defaults)
                (builtins.removeAttrs svc.service ["script"])
                # Script handled separately (not in serviceConfig)
                (lib.mkIf ((svc.service.script or null) != null) {
                  inherit (svc.service) script;
                })
              ];
            })
          ]
      )
      enabledServices)
    # ── MQTT ACL accumulation ────────────────────────────────
    ++ lib.optional (mqttAcls != {}) {
      mqtt.users =
        lib.mapAttrs (_user: acls: {
          acl = acls;
        })
        mqttAcls;
    }
  ));
}
