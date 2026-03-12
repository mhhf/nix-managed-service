# Extract DNS records from nixosConfigurations
#
# Usage:
#   records = nix-managed-service.lib.extractDnsRecords {
#     inherit lib nixosConfigurations;
#   };
#   # Returns: [{ domain = "media.example.com"; ip = "100.x.y.z"; } ...]
#
# IP resolution:
#   - publicAccess=true services use config.proxy.publicAddress
#   - Other services use config.proxy.listenAddress
#   - Records with null IP are filtered out
{
  lib,
  nixosConfigurations,
}:
lib.concatMap (
  cfg: let
    listenAddress = cfg.config.proxy.listenAddress or null;
    publicAddress = cfg.config.proxy.publicAddress or null;

    enabledServices =
      lib.filterAttrs
      (_: svc: svc.enable or false)
      (cfg.config.proxy.services or {});

    enabledStaticSites =
      lib.filterAttrs
      (_: site: site.enable or false)
      (cfg.config.proxy.staticSites or {});

    resolveIp = isPublic:
      if isPublic && publicAddress != null
      then publicAddress
      else listenAddress;

    serviceRecords =
      lib.mapAttrsToList (_: svc: {
        inherit (svc) domain;
        ip = resolveIp (svc.publicAccess or false);
      })
      enabledServices;

    staticSiteRecords =
      lib.mapAttrsToList (_: site: {
        inherit (site) domain;
        ip = resolveIp (site.publicAccess or false);
      })
      enabledStaticSites;
  in
    lib.filter (r: r.ip != null) (serviceRecords ++ staticSiteRecords)
) (lib.attrValues nixosConfigurations)
