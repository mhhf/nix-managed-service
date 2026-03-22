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

  # ── Secrets helpers ───────────────────────────────────────────
  hasSops = options ? sops && options.sops ? secrets;

  secretSpecType = lib.types.either lib.types.str (lib.types.submodule {
    options = {
      key = lib.mkOption {
        type = lib.types.str;
        description = "Key in sops file";
      };
      sopsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Override sops file for this secret";
      };
    };
  });

  resolveSecretSpec = spec: defaultSopsFile:
    if builtins.isString spec
    then {
      key = spec;
      sopsFile = defaultSopsFile;
    }
    else {
      inherit (spec) key;
      sopsFile =
        if spec.sopsFile != null
        then spec.sopsFile
        else defaultSopsFile;
    };

  secretAttrName = svcName: key: "${svcName}-${key}";

  computeRestartUnits = name: svc:
    svc.secrets.restartUnits
    ++ lib.optional (svc.service != null) "${svc.serviceName}.service";

  hasAnySec = svc: svc.secrets.envVars != {} || svc.secrets.credentials != {} || svc.secrets.files != {};

  managedServiceModule = lib.types.submodule ({
    name,
    config,
    ...
  }: let
    svcName = name;
  in {
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

        # ── Auto-deploy triggers ────────────────────────────────
        on = {
          ci = lib.mkOption {
            type = lib.types.nullOr (lib.types.either lib.types.str (lib.types.submodule {
              options = {
                repo = lib.mkOption {type = lib.types.str;};
                branch = lib.mkOption {
                  type = lib.types.str;
                  default = "main";
                };
              };
            }));
            default = null;
            description = "Trigger deploy on CI pass. Same shorthand as on.ci.";
          };

          schedule = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Trigger periodic redeploy on this calendar expression.";
          };

          mqtt = lib.mkOption {
            type = lib.types.nullOr (lib.types.submodule {
              options = {
                topic = lib.mkOption {type = lib.types.str;};
                filter = lib.mkOption {
                  type = lib.types.attrsOf lib.types.str;
                  default = {};
                };
                jqFilter = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = ''
                    Raw jq expression for payload filtering. When set, overrides filter.
                    Mutually exclusive with filter.
                  '';
                };
              };
            });
            default = null;
            description = "Raw MQTT deploy trigger (escape hatch).";
          };
        };

        preDeploy = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Shell script to run before the build + slot swap.
            Runs as ExecStartPre (after the flock, before the build).
          '';
        };

        postDeploy = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Shell script to run after service restart following deploy.
            Runs as ExecStartPost.
          '';
        };

        healthCheck = lib.mkOption {
          type = lib.types.nullOr (lib.types.submodule {
            options = {
              url = lib.mkOption {
                type = lib.types.str;
                description = "HTTP URL to check after deploy (curl -sf).";
              };
              timeout = lib.mkOption {
                type = lib.types.int;
                default = 30;
                description = "Seconds to wait for the health check to pass before rolling back.";
              };
            };
          });
          default = null;
          description = ''
            Post-deploy health check. When set, the deploy script polls the URL
            for up to timeout seconds after the service restart. If the check
            fails, it rolls back to the previous slot and restarts the service.
          '';
        };

        source = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Path to local source repo (kept current by src-sync).";
        };

        buildExpr = lib.mkOption {
          type = lib.types.str;
          default = ".#default";
          description = "Nix build expression for deploy script.";
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
          then let
            rwPaths =
              lib.filter (x: x != null) [config.stateDir config.outputDir]
              ++ lib.mapAttrsToList (_: d: d.path) config.extraDirs;
          in
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
            // lib.optionalAttrs (rwPaths != []) {
              ReadWritePaths = rwPaths;
            }
          else if p == "standard"
          then let
            rwPaths =
              lib.filter (x: x != null) [config.stateDir config.outputDir]
              ++ lib.mapAttrsToList (_: d: d.path) config.extraDirs;
          in
            {
              NoNewPrivileges = true;
              PrivateTmp = true;
              ProtectSystem = "strict";
              ProtectHome = true;
            }
            // lib.optionalAttrs (rwPaths != []) {
              ReadWritePaths = rwPaths;
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

      # ── Triggers (on.*) ─────────────────────────────────────────
      on = {
        ci = lib.mkOption {
          type = lib.types.nullOr (lib.types.either lib.types.str (lib.types.submodule {
            options = {
              repo = lib.mkOption {type = lib.types.str;};
              branch = lib.mkOption {
                type = lib.types.str;
                default = "main";
                description = ''
                  Branch to match. Use "*" for any branch, or "prefix/*" for prefix match.
                '';
              };
            };
          }));
          default = null;
          description = ''
            Trigger on CI pass. String shorthand:
              on.ci = "calc"  →  topic git/ci/calc, filter {status=PASS, branch=main}
            Attrset for custom branch:
              on.ci = { repo = "calc"; branch = "develop"; }
            Wildcard:
              on.ci = { repo = "calc"; branch = "*"; }  →  any branch
              on.ci = { repo = "calc"; branch = "feature/*"; }  →  prefix match
          '';
        };

        schedule = lib.mkOption {
          type = lib.types.nullOr (lib.types.either lib.types.str (lib.types.submodule {
            options = {
              calendar = lib.mkOption {type = lib.types.str;};
              ifNewCommits = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Path to a git repo. Skip run (ExecCondition) if HEAD unchanged
                  since last successful run. SHA stored in stateDir/.last-trigger-sha.
                '';
              };
            };
          }));
          default = null;
          description = ''
            Schedule trigger. String = always run:
              on.schedule = "daily"
            Attrset = conditional:
              on.schedule = { calendar = "daily"; ifNewCommits = "/var/lib/src/calc"; }
          '';
        };

        mqtt = lib.mkOption {
          type = lib.types.nullOr (lib.types.submodule {
            options = {
              topic = lib.mkOption {type = lib.types.str;};
              filter = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = {};
              };
              jqFilter = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Raw jq expression for payload filtering. When set, overrides filter.
                  Mutually exclusive with filter.
                  Example: ".temperature > 20 and .unit == \"C\""
                '';
              };
            };
          });
          default = null;
          description = "Raw MQTT trigger for topics outside git/ci/*.";
        };

        publishStatus = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Publish MQTT status messages for this job service.
            When true, publishes to "jobs/<name>/status" on start (ExecStartPre)
            and completion (ExecStopPost), including exit code and service result.
            Requires the trigger-mqtt MQTT user to be configured.
          '';
        };
      };

      overlap = lib.mkOption {
        type = lib.types.enum ["skip" "cancel"];
        default = "skip";
        description = ''
          Policy when an MQTT trigger fires while the service is already running:
          - "skip": ignore the trigger (default behavior)
          - "cancel": stop the current run and start a new one (systemctl restart)
        '';
      };

      triggerRateLimit = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            interval = lib.mkOption {
              type = lib.types.str;
              description = ''
                Minimum time between triggers. Parsed as seconds or with suffix:
                "30s", "5m", "1h", "2h30m".
              '';
              example = "1h";
            };
          };
        });
        default = null;
        description = ''
          Rate limit MQTT triggers. When set, the dispatch script checks a
          timestamp file and skips the trigger if fired within the interval.
        '';
      };

      concurrencyGroup = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Concurrency group name. Services sharing a group are serialized via flock(2).";
      };

      outputDir = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          Output directory for job results. Framework creates it via tmpfiles,
          adds to ReadWritePaths, and injects OUTPUT_DIR env var.
        '';
      };

      outputCommit = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.str (lib.types.submodule {
          options = {
            message = lib.mkOption {type = lib.types.str;};
            repo = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Git repo path. Auto-detected from outputDir if null.";
            };
            paths = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [];
              description = "Paths to git add. Defaults to outputDir.";
            };
          };
        }));
        default = null;
        description = ''
          Semantic git commit after job success. String shorthand:
            outputCommit = "compiled: calc benchmarks"
          Requires outputDir (or explicit paths in attrset form).
        '';
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

      # ── Secrets ───────────────────────────────────────────────────
      secrets = {
        sopsFile = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Default sops file for this service's secrets.";
        };

        envVars = lib.mkOption {
          type = lib.types.attrsOf secretSpecType;
          default = {};
          description = ''
            Environment variables populated from sops secrets.
            String shorthand: envVars.FOO = "foo_key" → reads "foo_key" from secrets.sopsFile.
            Attrset: envVars.FOO = { key = "foo_key"; sopsFile = ./other.yaml; }.
            Generates sops.secrets + sops.templates env file + EnvironmentFile on service.
          '';
          example = {
            TELEGRAM_BOT_TOKEN = "telegram_bot_token";
            API_KEY = {
              key = "my_api_key";
              sopsFile = ./keys.yaml;
            };
          };
        };

        credentials = lib.mkOption {
          type = lib.types.attrsOf secretSpecType;
          default = {};
          description = ''
            Secrets exposed via systemd LoadCredential.
            String shorthand: credentials.mqtt-password = "mqtt_pw_key".
            Service reads via: cat $CREDENTIALS_DIRECTORY/mqtt-password
            Generates sops.secrets + LoadCredential on the systemd service.
          '';
        };

        files = lib.mkOption {
          type = lib.types.attrsOf (lib.types.submodule ({name, ...}: {
            options = {
              key = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Key in sops file. null or empty string = whole file.";
              };
              sopsFile = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
                description = "Override sops file for this secret file.";
              };
              format = lib.mkOption {
                type = lib.types.str;
                default = "yaml";
                description = "Sops file format (yaml, json, binary, etc.)";
              };
              mode = lib.mkOption {
                type = lib.types.str;
                default = "0400";
              };
              owner = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Override owner (defaults to service user).";
              };
              path = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                readOnly = true;
                default =
                  if hasSops
                  then outerConfig.sops.secrets."${svcName}-${name}".path
                  else null;
                description = "Resolved sops secret path. Null when sops-nix is not loaded.";
              };
            };
          }));
          default = {};
          description = ''
            Named secret files. Each generates a sops.secrets entry.
            The resolved path is available as secrets.files.<name>.path (read-only).
          '';
        };

        restartUnits = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = ''
            Extra units to restart when secrets change.
            The service's own unit is auto-added when service != null.
          '';
        };
      };

      # ── Runtime hint ──────────────────────────────────────────────
      runtime = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum ["node"]);
        default = null;
        description = "Runtime hint. 'node' auto-sets NODE_ENV=production.";
      };

      # ── Extra directories ─────────────────────────────────────────
      extraDirs = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            path = lib.mkOption {type = lib.types.str;};
            mode = lib.mkOption {
              type = lib.types.str;
              default = "0750";
            };
            user = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Owner user (defaults to service user).";
            };
            group = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Owner group (defaults to service group).";
            };
          };
        });
        default = {};
        description = "Additional directories to create via tmpfiles (beyond stateDir).";
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
  in
    {
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

      # ── State directories + output directories ─────────────────────
      systemd.tmpfiles.rules = lib.concatLists (lib.mapAttrsToList (_: svc:
        lib.optional (svc.stateDir != null && svc.user != null)
        "d ${svc.stateDir} 0750 ${svc.user} ${svc.group} -"
        ++ lib.optional (svc.outputDir != null && svc.user != null)
        "d ${svc.outputDir} 0750 ${svc.user} ${svc.group} -"
        ++ lib.mapAttrsToList (_: dir: let
          u =
            if dir.user != null
            then dir.user
            else if svc.user != null
            then svc.user
            else "root";
          g =
            if dir.group != null
            then dir.group
            else if svc.group != null
            then svc.group
            else "root";
        in "d ${dir.path} ${dir.mode} ${u} ${g} -")
        svc.extraDirs)
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
              # outputCommit requires outputDir (unless explicit paths)
              ++ lib.optional (svc.outputCommit != null && svc.outputDir == null) {
                assertion = false;
                message = "managedServices.${name}: outputCommit requires outputDir to be set";
              }
              # deployment.on.* requires deployment.source
              ++ lib.optional ((svc.deployment.on.ci != null || svc.deployment.on.schedule != null || svc.deployment.on.mqtt != null) && svc.deployment.source == null) {
                assertion = false;
                message = "managedServices.${name}: deployment.on.* triggers require deployment.source to be set";
              }
              # deployment.on.* requires slot.enable
              ++ lib.optional ((svc.deployment.on.ci != null || svc.deployment.on.schedule != null || svc.deployment.on.mqtt != null) && !svc.deployment.slot.enable) {
                assertion = false;
                message = "managedServices.${name}: deployment.on.* triggers require deployment.slot.enable = true";
              }
              # on.mqtt: jqFilter and filter are mutually exclusive
              ++ lib.optional (svc.on.mqtt != null && svc.on.mqtt.jqFilter != null && svc.on.mqtt.filter != {}) {
                assertion = false;
                message = "managedServices.${name}: on.mqtt.jqFilter and on.mqtt.filter are mutually exclusive — use only one";
              }
              # deployment.on.mqtt: jqFilter and filter are mutually exclusive
              ++ lib.optional (svc.deployment.on.mqtt != null && svc.deployment.on.mqtt.jqFilter != null && svc.deployment.on.mqtt.filter != {}) {
                assertion = false;
                message = "managedServices.${name}: deployment.on.mqtt.jqFilter and deployment.on.mqtt.filter are mutually exclusive — use only one";
              }
              # deployment.healthCheck requires deployment.source (for rollback)
              ++ lib.optional (svc.deployment.healthCheck != null && svc.deployment.source == null) {
                assertion = false;
                message = "managedServices.${name}: deployment.healthCheck requires deployment.source to be set";
              }
              # secrets.sopsFile required when string shorthand is used in envVars/credentials
              ++ lib.optional (svc.secrets.sopsFile
                == null
                && (
                  lib.any builtins.isString (lib.attrValues svc.secrets.envVars)
                  || lib.any builtins.isString (lib.attrValues svc.secrets.credentials)
                )) {
                assertion = false;
                message = "managedServices.${name}: secrets.sopsFile must be set when using string shorthand in envVars/credentials";
              }
              # Each secrets.files entry must have sopsFile coverage
              ++ lib.concatLists (lib.mapAttrsToList (
                  fileName: spec:
                    lib.optional (spec.sopsFile == null && svc.secrets.sopsFile == null) {
                      assertion = false;
                      message = "managedServices.${name}: secrets.files.${fileName} has no sopsFile (set it on the file or on secrets.sopsFile)";
                    }
                )
                svc.secrets.files)
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
              # Slot services: binary lifecycle managed by CI, not nixos-rebuild.
              # Prevent deploy-rs from restarting on config change — CI triggers
              # handle restarts after slot updates. Seed provides the initial binary.
              restartIfChanged = lib.mkIf svc.deployment.slot.enable (lib.mkDefault false);
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
            # OUTPUT_DIR env injection
            (lib.mkIf (svc.outputDir != null) {
              environment.OUTPUT_DIR = lib.mkDefault svc.outputDir;
            })
            # Runtime hint: NODE_ENV=production for Node.js services
            (lib.mkIf (svc.runtime == "node") {
              environment.NODE_ENV = lib.mkDefault "production";
            })
            # Secrets: EnvironmentFile from sops.templates
            (lib.mkIf (hasSops && svc.secrets.envVars != {}) {
              serviceConfig.EnvironmentFile = outerConfig.sops.templates."${name}-env".path;
            })
            # Secrets: LoadCredential from sops.secrets
            (lib.mkIf (hasSops && svc.secrets.credentials != {}) {
              serviceConfig.LoadCredential = lib.mapAttrsToList (credName: spec: let
                resolved = resolveSecretSpec spec svc.secrets.sopsFile;
              in "${credName}:${outerConfig.sops.secrets."${name}-${credName}".path}")
              svc.secrets.credentials;
            })
            # Secrets: auto after/wants sops-nix.service
            (lib.mkIf (hasSops && hasAnySec svc) {
              after = ["sops-nix.service"];
              wants = ["sops-nix.service"];
            })
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
    }
    // lib.optionalAttrs hasSops {
      # ── Sops secrets integration ─────────────────────────────────
      # Guarded by optionalAttrs (not mkIf) because the sops option namespace
      # only exists when sops-nix is imported. mkIf would still create a
      # definition entry that the module system rejects.
      sops.secrets = lib.mkMerge (lib.mapAttrsToList (name: svc: let
        envSecrets =
          lib.mapAttrs' (_envName: spec: let
            resolved = resolveSecretSpec spec svc.secrets.sopsFile;
          in {
            name = secretAttrName name resolved.key;
            value = {
              inherit (resolved) sopsFile key;
              mode = "0400";
              owner = lib.mkIf (svc.user != null) svc.user;
              restartUnits = computeRestartUnits name svc;
            };
          })
          svc.secrets.envVars;
        credSecrets =
          lib.mapAttrs' (credName: spec: let
            resolved = resolveSecretSpec spec svc.secrets.sopsFile;
          in {
            name = "${name}-${credName}";
            value = {
              inherit (resolved) sopsFile key;
              mode = "0400";
              owner = lib.mkIf (svc.user != null) svc.user;
              restartUnits = computeRestartUnits name svc;
            };
          })
          svc.secrets.credentials;
        fileSecrets =
          lib.mapAttrs' (fileName: spec: let
            effectiveOwner =
              if spec.owner != null
              then spec.owner
              else svc.user;
          in {
            name = "${name}-${fileName}";
            value = {
              sopsFile =
                if spec.sopsFile != null
                then spec.sopsFile
                else svc.secrets.sopsFile;
              inherit (spec) key format mode;
              owner = lib.mkIf (effectiveOwner != null) effectiveOwner;
              restartUnits = computeRestartUnits name svc;
            };
          })
          svc.secrets.files;
      in
        lib.mkIf (hasAnySec svc) (envSecrets // credSecrets // fileSecrets))
      enabled);

      sops.templates = lib.mkMerge (lib.mapAttrsToList (name: svc:
        lib.mkIf (svc.secrets.envVars != {}) {
          "${name}-env" = {
            content = lib.concatStringsSep "\n" (lib.mapAttrsToList (envName: spec: let
              resolved = resolveSecretSpec spec svc.secrets.sopsFile;
            in "${envName}=${outerConfig.sops.placeholder.${secretAttrName name resolved.key}}")
            svc.secrets.envVars);
            mode = "0400";
            owner = lib.mkIf (svc.user != null) svc.user;
            restartUnits = computeRestartUnits name svc;
          };
        })
      enabled);
    };
}
