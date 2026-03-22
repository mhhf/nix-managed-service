# Extract zone/workspace metadata from nixosConfigurations
#
# Usage:
#   zoneRegistry = nix-managed-service.lib.extractZoneRegistry {
#     inherit lib nixosConfigurations;
#   };
#   # Returns: { workspaces = [...]; access = [...]; }
#
# Sources:
#   - workspaces.* (workspace definitions)
#   - managedServices.*.access (service workspace participation)
{
  lib,
  nixosConfigurations,
}: let
  perHost = lib.concatMap (
    cfg: let
      hostName = cfg.config.networking.hostName or "unknown";
      wsCfg = cfg.config.workspaces or {};
      enabled = lib.filterAttrs (_: svc: svc.enable) (cfg.config.managedServices or {});

      workspaceEntries =
        lib.mapAttrsToList (name: ws: {
          inherit name;
          inherit (ws) path description owner group extraMembers;
          host = hostName;
        })
        wsCfg;

      accessEntries = lib.concatLists (lib.mapAttrsToList (
        svcName: svc:
          map (wsName: {
            service = svcName;
            workspace = wsName;
            user = svc.user;
            host = hostName;
          })
          svc.access
      ) (lib.filterAttrs (_: svc: svc.access != []) enabled));
    in [
      {
        inherit workspaceEntries accessEntries;
      }
    ]
  ) (lib.attrValues nixosConfigurations);
in {
  workspaces = lib.concatMap (h: h.workspaceEntries) perHost;
  access = lib.concatMap (h: h.accessEntries) perHost;
}
