# Unified managed service framework
#
# Each managedServices.<name> declaration generates:
#   - proxy.services.<name> (if domain is set)
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
{
  config,
  lib,
  options,
  ...
}: let
  outerConfig = config;
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
          When the proxy module is imported, proxy.services entries are auto-generated.
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

      websockets = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to enable WebSocket proxying (passed to proxy).";
      };

      # ── Deployment ─────────────────────────────────────────────
      deployment = {
        slotPath = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default =
            if config.deployment.slot.enable
            then "${outerConfig.slots.baseDir}/${name}/current"
            else null;
          description = ''
            Path to a symlink-based deployment slot.
            Auto-computed from slots.baseDir when deployment.slot.enable = true.
          '';
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

        slot = {
          enable = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Enable symlink-based deployment slot for this service.
              When true, slotPath is auto-computed from slots.basePath
              and the service is registered for scoped sudo restarts.
              Requires slots.enable = true at the fleet level.
            '';
          };

          restartUnit = lib.mkOption {
            type = lib.types.str;
            default = config.serviceName;
            description = ''
              Systemd unit to restart after slot deployment.
              Defaults to the service name. Override for containers
              (e.g. "container@bot").
            '';
          };
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
          then
            {
              DynamicUser = true;
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectControlGroups = true;
              RestrictSUIDSGID = true;
              # Note: RestrictNamespaces is omitted because DynamicUser requires
              # user namespace support. If you need namespace restriction, set
              # hardening = "none" and configure serviceConfig manually.
            }
            // lib.optionalAttrs (config.stateDir != null) {
              ReadWritePaths = [config.stateDir];
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
          - "strict": all of standard plus DynamicUser, kernel/cgroup protection, RestrictSUIDSGID
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

      # ── Health checks ────────────────────────────────────────────
      healthCheck = {
        http = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "HTTP URL to check (curl --fail). Mutually exclusive with tcp/exec.";
          example = "http://localhost:8080/health";
        };

        tcp = lib.mkOption {
          type = lib.types.nullOr lib.types.port;
          default = null;
          description = "TCP port to check (nc -z). Mutually exclusive with http/exec.";
        };

        exec = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Command to run as health check. Exit 0 = healthy.";
        };

        interval = lib.mkOption {
          type = lib.types.str;
          default = "60s";
          description = "How often to run the health check (systemd OnUnitActiveSec format).";
        };

        timeoutSec = lib.mkOption {
          type = lib.types.int;
          default = 10;
          description = "Timeout in seconds for the health check.";
        };

        onFailure = lib.mkOption {
          type = lib.types.enum ["restart" "notify"];
          default = "notify";
          description = ''
            Action on health check failure:
            - "restart": restart the service via systemd OnFailure
            - "notify": just log a warning to the journal
          '';
        };
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

  # Config uses a fixed-structure attrset so the module system can extract
  # definitions from static keys without forcing config.managedServices.
  # Values are lazy thunks — only evaluated when specific options are accessed,
  # at which point managedServices is already resolvable (no cycle).
  config = let
    cfg = config.managedServices;
    enabled = lib.filterAttrs (_: svc: svc.enable) cfg;

    hasMqtt = options ? mqtt && options.mqtt ? users;

    needsExecStart = svc:
      svc.service
      != null
      && (svc.service.script or null) == null
      && (svc.service.serviceConfig.ExecStart or null) == null;

    # Count how many health check types are set
    healthCheckCount = svc:
      (
        if svc.healthCheck.http != null
        then 1
        else 0
      )
      + (
        if svc.healthCheck.tcp != null
        then 1
        else 0
      )
      + (
        if svc.healthCheck.exec != null
        then 1
        else 0
      );

    # Collect all domains for collision detection
    allDomains =
      lib.filter (d: d != null)
      (lib.mapAttrsToList (_: svc: svc.domain) enabled);
    uniqueDomains = lib.unique allDomains;
  in {
    # ── Proxy registration ────────────────────────────────────────
    proxy.services = lib.mapAttrs (_name: svc:
      lib.mkIf (svc.domain != null) (
        {
          enable = true;
          inherit (svc) domain;
        }
        // lib.optionalAttrs (svc.port != null) {inherit (svc) port;}
        // lib.optionalAttrs (svc.target != null) {inherit (svc) target;}
        // lib.optionalAttrs (svc.locations != null) {inherit (svc) locations;}
        // lib.optionalAttrs (svc.description != null) {inherit (svc) description;}
        // lib.optionalAttrs svc.publicAccess {inherit (svc) publicAccess;}
        // lib.optionalAttrs (!svc.websockets) {inherit (svc) websockets;}
      ))
    enabled;

    # ── Users and groups ──────────────────────────────────────────
    users.users = lib.mkMerge (lib.mapAttrsToList (_: svc:
      lib.mkIf (svc.user != null) {
        ${svc.user} = {
          isSystemUser = true;
          group = svc.group;
          home = lib.mkIf (svc.stateDir != null) svc.stateDir;
          createHome = lib.mkIf (svc.stateDir != null) true;
        };
      })
    enabled);

    users.groups = lib.mkMerge (lib.mapAttrsToList (_: svc:
      lib.mkIf (svc.user != null) {
        ${svc.group} = {};
      })
    enabled);

    # ── State directories ─────────────────────────────────────────
    systemd.tmpfiles.rules = lib.concatLists (lib.mapAttrsToList (_: svc:
      lib.optional (svc.stateDir != null && svc.user != null)
      "d ${svc.stateDir} 0750 ${svc.user} ${svc.group} -")
    enabled);

    # ── Firewall ──────────────────────────────────────────────────
    networking.firewall.allowedTCPPorts =
      lib.concatLists (lib.mapAttrsToList (_: svc: svc.openPorts) enabled);

    networking.firewall.allowedUDPPorts =
      lib.concatLists (lib.mapAttrsToList (_: svc: svc.openUDPPorts) enabled);

    # ── Assertions ───────────────────────────────────────────────
    assertions =
      # Domain collision detection
      [
        {
          assertion = builtins.length allDomains == builtins.length uniqueDomains;
          message = "managedServices: duplicate domain detected — each service must have a unique domain";
        }
      ]
      ++ lib.concatLists (lib.mapAttrsToList (
          name: svc:
          # Deployment: ExecStart needs a binary
            lib.optional (needsExecStart svc) {
              assertion = svc.binaryPath != null;
              message = "managedServices.${name}: either deployment.slotPath or deployment.package must be set (needed for auto-generated ExecStart)";
            }
            # Health check: at most one type
            ++ lib.optional (healthCheckCount svc > 1) {
              assertion = false;
              message = "managedServices.${name}: healthCheck.http, .tcp, and .exec are mutually exclusive — set only one";
            }
            # Slot: requires fleet-level slots.enable
            ++ lib.optional (svc.deployment.slot.enable && !(config.slots.enable or false)) {
              assertion = false;
              message = "managedServices.${name}: deployment.slot.enable requires slots.enable = true";
            }
        )
        enabled);

    # ── Systemd services ──────────────────────────────────────────
    systemd.services = lib.mkMerge (lib.mapAttrsToList (name: svc:
      lib.mkIf (svc.service != null) {
        ${svc.serviceName} = lib.mkMerge [
          # Framework defaults (mkDefault — user overrides win naturally)
          {
            wantedBy = lib.mkDefault ["multi-user.target"];
            after = lib.mkDefault ["network.target"];
            serviceConfig = lib.mapAttrs (_: lib.mkDefault) (
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
              }
            );
          }
          # User overrides (merged on top of defaults)
          (builtins.removeAttrs svc.service ["script"])
          # Script handled separately (not in serviceConfig)
          (lib.mkIf ((svc.service.script or null) != null) {
            inherit (svc.service) script;
          })
        ];
      })
    enabled);

    # ── MQTT ACL accumulation ─────────────────────────────────────
    # Multiple services sharing an MQTT user get their ACLs merged
    # automatically via the module system's list concatenation.
    mqtt.users = lib.mkIf hasMqtt (
      lib.mkMerge (lib.mapAttrsToList (_: svc:
        lib.mkIf (svc.mqtt != null) {
          ${svc.mqtt.user}.acl = svc.mqtt.acl;
        })
      enabled)
    );
  };
}
