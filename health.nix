# Health check timers — generated from managedServices.*.healthCheck
#
# For each service with a healthCheck configured, generates:
#   - A systemd timer that fires on the configured interval
#   - A oneshot service that performs the check (http/tcp/exec)
#   - On failure: either restarts the target service or just logs a warning
#
# Usage:
#   managedServices.myapp.healthCheck = {
#     http = "http://localhost:8080/health";
#     interval = "60s";
#     timeout = "10s";
#     onFailure = "restart";
#   };
{
  config,
  lib,
  pkgs,
  ...
}: let
  managedCfg = config.managedServices;

  # Collect services with health checks enabled
  hasHealthCheck = svc:
    svc.healthCheck.http
    != null
    || svc.healthCheck.tcp != null
    || svc.healthCheck.exec != null;

  healthChecked =
    lib.filterAttrs (
      _: svc:
        svc.enable && hasHealthCheck svc
    )
    managedCfg;

  # Generate the check script for a service
  mkCheckScript = name: svc: let
    hc = svc.healthCheck;
    timeoutSec = toString hc.timeoutSec;
    checkCmd =
      if hc.http != null
      then ''${pkgs.curl}/bin/curl --fail --silent --max-time ${timeoutSec} "${hc.http}" > /dev/null''
      else if hc.tcp != null
      then ''${pkgs.libressl.nc}/bin/nc -z -w ${timeoutSec} localhost ${toString hc.tcp}''
      else hc.exec;
    failAction =
      if hc.onFailure == "restart"
      then ''
        echo "Health check failed for ${name}, restarting ${svc.serviceName}" | ${pkgs.systemd}/bin/systemd-cat -t healthcheck -p err
        exit 1
      ''
      else ''
        echo "Health check failed for ${name}" | ${pkgs.systemd}/bin/systemd-cat -t healthcheck -p warning
      '';
  in
    pkgs.writeShellScript "healthcheck-${name}" ''
      set -euo pipefail
      if ${checkCmd}; then
        exit 0
      else
        ${failAction}
      fi
    '';
in {
  # Health check options are declared in module.nix as part of managedServiceModule.
  # This file only generates config from those options.

  config = lib.mkIf (healthChecked != {}) {
    systemd = {
      timers =
        lib.mapAttrs' (
          name: svc:
            lib.nameValuePair "healthcheck-${name}" {
              wantedBy = ["timers.target"];
              timerConfig = {
                OnBootSec = "120s";
                OnUnitActiveSec = svc.healthCheck.interval;
              };
            }
        )
        healthChecked;

      services = lib.mkMerge [
        # Health check oneshot services
        (lib.mapAttrs' (
            name: svc:
              lib.nameValuePair "healthcheck-${name}" {
                description = "Health check for ${name}";
                serviceConfig = {
                  Type = "oneshot";
                  ExecStart = mkCheckScript name svc;
                };
                unitConfig = lib.mkIf (svc.healthCheck.onFailure == "restart") {
                  OnFailure = "healthcheck-restart-${name}.service";
                };
              }
          )
          healthChecked)
        # Restart helper services (OnFailure can only start units, not restart them)
        (lib.mapAttrs' (
          name: svc:
            lib.nameValuePair "healthcheck-restart-${name}" {
              description = "Restart ${svc.serviceName} after failed health check";
              serviceConfig = {
                Type = "oneshot";
                ExecStart = "${pkgs.systemd}/bin/systemctl restart ${svc.serviceName}.service";
              };
            }
        ) (lib.filterAttrs (_: svc: svc.healthCheck.onFailure == "restart") healthChecked))
      ];
    };
  };
}
