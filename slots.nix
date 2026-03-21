# Deployment slot infrastructure — accumulated from managed services
#
# Individual services declare deployment.slot.enable = true.
# This module collects all slot-enabled services and generates:
#   - A deploy user with SSH keys and scoped sudo
#   - Per-slot directories under basePath
#   - Nix trusted-user for `nix copy --to ssh://`
#
# Fleet-level settings:
#   slots = {
#     enable = true;
#     deployKeys = [ "ssh-ed25519 AAAA..." ];
#   };
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.slots;
  managedCfg = config.managedServices;

  # Collect all slot-enabled services
  slotServices =
    lib.filterAttrs (
      _: svc:
        svc.enable && svc.deployment.slot.enable
    )
    managedCfg;

  slotNames = lib.attrNames slotServices;

  # Slot services with a seed package (for initial population)
  seededSlots =
    lib.filterAttrs (
      _: svc:
        svc.deployment.package != null
    )
    slotServices;

  # Collect restart units: each slot-enabled service contributes its restartUnit
  restartUnits =
    lib.mapAttrsToList (
      _: svc:
        svc.deployment.slot.restartUnit
    )
    slotServices;

  hasSlots = cfg.enable && slotNames != [];
in {
  options.slots = {
    enable = lib.mkEnableOption "deployment slot infrastructure for symlink deployments";

    baseDir = lib.mkOption {
      type = lib.types.str;
      default = "/srv/apps";
      description = ''
        Base directory for all app slots.
        Each slot gets a subdirectory here (e.g. `/srv/apps/myapp/`).
      '';
    };

    deployUser = lib.mkOption {
      type = lib.types.str;
      default = "deploy";
      description = ''
        Name of the deployment user. This user gets:
        - SSH access via `deployKeys`
        - Ownership of slot directories
        - Scoped sudo for restarting slot-enabled services
      '';
    };

    deployKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = ''
        SSH public keys authorized for the deploy user.
        Typically a CI system's key (e.g. from pico-ci or GitHub Actions).
      '';
    };

    trustedUser = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to add the deploy user to `nix.settings.trusted-users`.
        Required for `nix copy --to ssh://deploy@host` to work.
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [pkgs.jq];
      description = "Extra packages to install for deployment tooling.";
    };
  };

  config = lib.mkIf hasSlots {
    # Deploy user
    users.users.${cfg.deployUser} = {
      isNormalUser = true;
      home = "/home/${cfg.deployUser}";
      shell = pkgs.bash;
      description = "Deployment user for app-slot deployments";
      group = cfg.deployUser;
      openssh.authorizedKeys.keys = cfg.deployKeys;
    };

    users.groups.${cfg.deployUser} = {};

    # Trust deploy user for nix copy
    nix.settings.trusted-users = lib.mkIf cfg.trustedUser [cfg.deployUser];

    # Slot directories
    systemd.tmpfiles.rules =
      ["d ${cfg.baseDir} 0755 root root -"]
      ++ map (name: "d ${cfg.baseDir}/${name} 0755 ${cfg.deployUser} ${cfg.deployUser} -") slotNames;

    # Scoped sudo — deploy can only restart specific services
    security.sudo.extraRules = lib.mkIf (restartUnits != []) [
      {
        users = [cfg.deployUser];
        commands =
          map (unit: {
            command = "/run/current-system/sw/bin/systemctl restart ${unit}";
            options = ["NOPASSWD"];
          })
          restartUnits;
      }
    ];

    # Seed slots from deployment.package on every activation.
    # The NixOS closure is the source of truth for what version runs.
    # CI deploys can override the slot for fast iteration, but the
    # next NixOS deploy resets it to the closure version.
    system.activationScripts.slotSeed = lib.mkIf (seededSlots != {}) {
      deps = ["specialfs"];
      text = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: svc: let
          slotDir = "${cfg.baseDir}/${name}";
          pkg = svc.deployment.package;
        in ''
          current=$(readlink "${slotDir}/current" 2>/dev/null || true)
          if [ "$current" != "${pkg}" ]; then
            echo "slot-seed: setting ${name} to closure package"
            ln -sfn "${pkg}" "${slotDir}/current.tmp"
            mv -fT "${slotDir}/current.tmp" "${slotDir}/current"
          fi
        '')
        seededSlots);
    };

    # Extra packages
    environment.systemPackages = cfg.extraPackages;
  };
}
