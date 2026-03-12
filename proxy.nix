# Declarative NGINX reverse proxy + ACME
#
# Provides two option namespaces:
#   proxy.services.*    — reverse proxies with auto port detection
#   proxy.staticSites.* — static file serving
#
# Automatically generates:
#   - NGINX virtualHosts with SSL
#   - ACME certificates via DNS-01 challenge
#   - Private (bind to specific IP) or public (all interfaces) access
#
# Usage:
#   proxy.listenAddress = "100.x.y.z";  # private IP (e.g. Tailscale)
#   proxy.acme = {
#     email = "admin@example.com";
#     dnsProvider = "gandiv5";
#     credentialsFile = "/run/secrets/acme-env";
#   };
#   proxy.services.jellyfin = {
#     enable = true;
#     domain = "media.example.com";
#     # port auto-detected (8096)
#   };
{
  config,
  lib,
  ...
}: let
  cfg = config.proxy;

  # Get all enabled proxy configurations
  servicesWithProxy =
    lib.filterAttrs
    (_: svc: svc.enable)
    cfg.services;

  # Get all enabled static sites
  staticSitesEnabled =
    lib.filterAttrs
    (_: site: site.enable)
    cfg.staticSites;

  # Common service port defaults (auto-detection)
  commonPorts = {
    grafana = 3000;
    prometheus = 9090;
    alertmanager = 9093;
    jellyfin = 8096;
    sonarr = 8989;
    radarr = 7878;
    lidarr = 8686;
    prowlarr = 9696;
    transmission = 9091;
    deluge = 8112;
    jackett = 9117;
    nzbget = 6789;
    sabnzbd = 8080;
  };

  # Generate listen config based on publicAccess flag
  mkListenConfig = publicAccess:
    if publicAccess
    then [] # Default NGINX behavior (all interfaces)
    else if cfg.listenAddress != null
    then [
      {
        addr = cfg.listenAddress;
        port = 80;
      }
    ]
    else [];

  mkSslExtraConfig = publicAccess:
    if publicAccess
    then ""
    else if cfg.listenAddress != null
    then "listen ${cfg.listenAddress}:443 ssl;"
    else "";

  # Generate NGINX vhosts for proxy services
  nginxVhosts =
    lib.mapAttrs' (
      serviceName: proxyCfg: let
        port =
          if proxyCfg.port != null
          then proxyCfg.port
          else commonPorts.${serviceName}
            or (throw "proxy.services.${serviceName}: port must be specified (no auto-detect default for this service)");

        proxyTarget =
          if proxyCfg.target != null
          then proxyCfg.target
          else "http://127.0.0.1:${toString port}";

        defaultLocations = {
          "/" = {
            proxyPass = proxyTarget;
            proxyWebsockets = proxyCfg.websockets;
          };
        };

        locations =
          if proxyCfg.locations != {}
          then proxyCfg.locations
          else defaultLocations;
      in
        lib.nameValuePair proxyCfg.domain {
          useACMEHost = proxyCfg.domain;
          forceSSL = true;
          listen = mkListenConfig proxyCfg.publicAccess;
          extraConfig = mkSslExtraConfig proxyCfg.publicAccess;
          inherit locations;
        }
    )
    servicesWithProxy;

  # Generate NGINX vhosts for static sites
  staticSiteVhosts =
    lib.mapAttrs' (
      _: siteCfg:
        lib.nameValuePair siteCfg.domain {
          useACMEHost = siteCfg.domain;
          forceSSL = true;
          listen = mkListenConfig siteCfg.publicAccess;
          extraConfig = mkSslExtraConfig siteCfg.publicAccess;
          inherit (siteCfg) root;
        }
    )
    staticSitesEnabled;

  allVhosts = nginxVhosts // staticSiteVhosts;

  # Collect all domains for ACME
  serviceDomains = lib.mapAttrsToList (_: svc: svc.domain) servicesWithProxy;
  staticSiteDomains = lib.mapAttrsToList (_: site: site.domain) staticSitesEnabled;
  allDomains = serviceDomains ++ staticSiteDomains;

  # Generate tmpfiles.rules for static site directories
  staticSiteTmpfiles = lib.mapAttrsToList (
    _: siteCfg: "d ${siteCfg.root} ${siteCfg.permissions} ${siteCfg.user} ${siteCfg.group} -"
  ) (lib.filterAttrs (_: site: site.createDirectory) staticSitesEnabled);
in {
  # ===========================================================================
  # Options
  # ===========================================================================

  options.proxy = {
    listenAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        IP address to bind private services to (e.g., Tailscale IP).
        Services with publicAccess=false will only listen on this address.
        If null, all services listen on all interfaces.
      '';
      example = "100.x.y.z";
    };

    publicAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Public IP address of this host. Used by the DNS extraction helper
        (lib.extractDnsRecords) for services with publicAccess=true.
        Not used by NGINX itself.
      '';
    };

    acme = {
      email = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Email for ACME account registration (required when services are defined)";
      };

      dnsProvider = lib.mkOption {
        type = lib.types.str;
        default = "gandiv5";
        description = "DNS provider name for ACME DNS-01 challenge (lego provider name)";
      };

      credentialsFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Path to environment file with DNS provider credentials.
          For gandiv5: file should contain GANDIV5_API_KEY=your-key
          For cloudflare: CF_DNS_API_TOKEN=your-token
          See https://go-acme.github.io/lego/dns/ for provider-specific variables.
        '';
      };
    };

    services = lib.mkOption {
      default = {};
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "NGINX reverse proxy for this service";

          domain = lib.mkOption {
            type = lib.types.str;
            description = "Domain name (e.g., 'app.example.com')";
          };

          port = lib.mkOption {
            type = lib.types.nullOr lib.types.port;
            default = null;
            description = ''
              Port to proxy to on localhost.
              Auto-detected for common services (jellyfin, grafana, etc.).
              Must be specified for custom services.
            '';
          };

          target = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = ''
              Custom proxy target URL (e.g., 'http://192.168.1.2:9091').
              If set, overrides the default localhost:port behavior.
              Useful for proxying to containers or other machines.
            '';
          };

          websockets = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Enable WebSocket support for this proxy";
          };

          publicAccess = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = ''
              Listen on all interfaces (public).
              If false, only accessible via proxy.listenAddress (private).
            '';
          };

          description = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Human-readable description (for documentation/dashboards)";
          };

          locations = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = {};
            description = ''
              Custom NGINX locations. If set, replaces the default "/" proxy.
              Use for FastCGI, custom configs, etc.
            '';
          };
        };
      });
    };

    staticSites = lib.mkOption {
      default = {};
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          enable = lib.mkEnableOption "NGINX static site hosting";

          domain = lib.mkOption {
            type = lib.types.str;
            description = "Domain name (e.g., 'blog.example.com')";
          };

          root = lib.mkOption {
            type = lib.types.str;
            description = "Root directory for static files";
          };

          createDirectory = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Auto-create root directory via tmpfiles";
          };

          permissions = lib.mkOption {
            type = lib.types.str;
            default = "0755";
          };

          user = lib.mkOption {
            type = lib.types.str;
            default = "root";
          };

          group = lib.mkOption {
            type = lib.types.str;
            default = "root";
          };

          publicAccess = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Listen on all interfaces (public) vs proxy.listenAddress only (private)";
          };
        };
      });
    };
  };

  # ===========================================================================
  # Config
  # ===========================================================================

  config = lib.mkMerge [
    # Assertions
    {
      assertions = [
        {
          assertion = allDomains == [] || (cfg.acme.email != "" && cfg.acme.credentialsFile != null);
          message = "proxy.acme.email and proxy.acme.credentialsFile must be set when proxy services or static sites are configured";
        }
      ];
    }

    # NGINX
    (lib.mkIf (allVhosts != {}) {
      services.nginx = {
        enable = true;
        virtualHosts = allVhosts;
      };
    })

    # ACME certificates
    (lib.mkIf (allDomains != [] && cfg.acme.credentialsFile != null) {
      security.acme = {
        acceptTerms = true;
        defaults.email = cfg.acme.email;

        certs = lib.genAttrs allDomains (_: {
          dnsProvider = cfg.acme.dnsProvider;
          credentialsFile = cfg.acme.credentialsFile;
          group = "nginx";
        });
      };
    })

    # Static site directories
    (lib.mkIf (staticSiteTmpfiles != []) {
      systemd.tmpfiles.rules = staticSiteTmpfiles;
    })
  ];
}
