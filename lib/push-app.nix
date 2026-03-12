# Generate a dnscontrol-based DNS push app from nixosConfigurations.
#
# Extracts all proxy.services.* and proxy.staticSites.* domains, groups them
# by zone, and generates a dnscontrol config + push script.
#
# Usage in flake.nix:
#   apps.x86_64-linux.push_dns = nix-managed-service.lib.mkDnsPushApp {
#     pkgs = import nixpkgs { system = "x86_64-linux"; };
#     nixosConfigurations = self.nixosConfigurations;
#     zones = {
#       "example.com" = {
#         provider = { type = "GANDI_V5"; envVar = "GAND_API"; };
#         extraRecords = [ ''MX("@", 10, "mail.example.com.")'' ];
#       };
#     };
#   };
#
# Returns: { type = "app"; program = "/nix/store/.../bin/push_dns"; }
{
  pkgs,
  lib ? pkgs.lib,
  nixosConfigurations,
  zones,
}: let
  # ── Extract DNS records from all nixosConfigurations ──────────────────
  allRecords = import ./dns.nix {inherit lib nixosConfigurations;};

  # ── Domain helpers ────────────────────────────────────────────────────
  belongsToZone = zone: domain:
    domain == zone || lib.hasSuffix ".${zone}" domain;

  # "git.example.com" under zone "example.com" → "git"
  # "example.com"     under zone "example.com" → "@"
  subdomainOf = zone: domain:
    if domain == zone
    then "@"
    else lib.removeSuffix ".${zone}" domain;

  # ── Collect unique providers across all zones ─────────────────────────
  allProviders = lib.attrValues (
    lib.foldl'
    (acc: z: acc // {${z.provider.type} = z.provider;})
    {}
    (lib.attrValues zones)
  );

  # ── Generate dnsconfig.js ────────────────────────────────────────────
  providerDecls =
    lib.concatMapStringsSep "\n"
    (p: ''var ${p.type} = NewDnsProvider("${p.type}");'')
    allProviders;

  mkZoneBlock = zoneName: zoneCfg: let
    zoneRecords = lib.filter (r: belongsToZone zoneName r.domain) allRecords;
    autoRecords =
      map (r: ''A("${subdomainOf zoneName r.domain}", "${r.ip}")'')
      zoneRecords;
    allZoneRecords = (zoneCfg.extraRecords or []) ++ autoRecords;
    ttl = zoneCfg.defaultTTL or "3h";
    recordsStr = lib.concatStringsSep ",\n    " allZoneRecords;
  in ''
    D("${zoneName}", REG, DnsProvider(${zoneCfg.provider.type}),
        DefaultTTL("${ttl}"),

        ${recordsStr}
    );'';

  zoneBlocks =
    lib.concatStringsSep "\n\n"
    (lib.mapAttrsToList mkZoneBlock zones);

  dnsconfig = pkgs.writeText "dnsconfig.js" ''
    var REG = NewRegistrar("none");
    ${providerDecls}

    ${zoneBlocks}
  '';

  # ── Generate push_dns script ──────────────────────────────────────────
  # Note: string concatenation is used to produce bash variable references
  # like ${GAND_API:-} and $GAND_API, since Nix's $${...} escapes interpolation
  # rather than producing a dollar sign followed by an interpolated value.
  mkEnvCheck = p:
    "if [ -z \""
    + "$"
    + "{"
    + p.envVar
    + ":-}\" ]; then\n"
    + "  echo \"Please export "
    + p.envVar
    + " with your "
    + p.type
    + " API token\" >&2\n"
    + "  exit 1\n"
    + "fi";
  envChecks = lib.concatMapStringsSep "\n" mkEnvCheck allProviders;

  mkCredEntry = p:
    "\""
    + p.type
    + "\": {\n"
    + "      \"TYPE\": \""
    + p.type
    + "\",\n"
    + "      \"token\": \""
    + "$"
    + p.envVar
    + "\"\n"
    + "    }";
  credEntries = lib.concatStringsSep ",\n    " (map mkCredEntry allProviders);

  push_dns = pkgs.writeShellApplication {
    name = "push_dns";
    runtimeInputs = [pkgs.dnscontrol];
    text = ''
      ${envChecks}

      workdir=$(mktemp -d)
      trap 'rm -rf "$workdir"' EXIT
      ln -s ${dnsconfig} "$workdir/dnsconfig.js"

      umask 077
      cat > "$workdir/creds.json" <<CREDSEOF
      {
        ${credEntries}
      }
      CREDSEOF

      cd "$workdir"
      exec dnscontrol push
    '';
  };
in {
  type = "app";
  program = "${push_dns}/bin/push_dns";
}
