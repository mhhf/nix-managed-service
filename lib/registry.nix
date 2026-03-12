# Extract service metadata from nixosConfigurations
#
# Usage:
#   allServices = nix-managed-service.lib.extractServiceRegistry {
#     inherit lib nixosConfigurations;
#   };
#   # Returns: [{ name; domain; description; type; host; } ...]
#
# Sources:
#   - managedServices.* (primary: services with domains)
#   - proxy.staticSites.* (secondary: static file hosting)
{
  lib,
  nixosConfigurations,
}:
lib.sort (a: b: a.domain < b.domain) (
  lib.concatMap (
    cfg: let
      hostName = cfg.config.networking.hostName or "unknown";

      # Primary: managed services with a domain
      managedEntries =
        lib.mapAttrsToList (name: svc: {
          inherit name;
          inherit (svc) domain description;
          type = "service";
          host = hostName;
        })
        (lib.filterAttrs
          (_: svc: svc.enable && svc.domain != null)
          (cfg.config.managedServices or {}));

      # Secondary: static sites
      staticEntries =
        lib.mapAttrsToList (name: siteCfg: {
          inherit name;
          inherit (siteCfg) domain;
          description = null;
          type = "static";
          host = hostName;
        })
        (lib.filterAttrs
          (_: siteCfg: siteCfg.enable or false)
          (cfg.config.proxy.staticSites or {}));
    in
      managedEntries ++ staticEntries
  ) (lib.attrValues nixosConfigurations)
)
