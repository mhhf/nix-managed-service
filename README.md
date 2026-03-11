# nix-managed-service

Declarative self-hosted service framework for NixOS. Define a service once, get all the infrastructure generated automatically.

## What it does

Each `managedServices.<name>` declaration generates:

- **Reverse proxy** — `proxy.services.<name>` entry (requires [nix-auto-proxy](https://github.com/mhhf/nix-auto-proxy) or compatible; gracefully skipped if not available)
- **System user/group** — created with proper home directory
- **State directory** — via `systemd.tmpfiles.rules` with correct ownership
- **Firewall rules** — TCP/UDP ports opened automatically
- **Systemd service** — with hardening presets, restart policy, and auto-generated `ExecStart`
- **Deployment assertion** — ensures either a Nix package or deployment slot path is configured
- **MQTT ACL accumulation** — multiple services sharing an MQTT user get their ACLs merged

## Usage

### Flake input

```nix
{
  inputs.nix-managed-service.url = "github:mhhf/nix-managed-service";

  outputs = { nix-managed-service, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nix-managed-service.nixosModules.default
        ./my-service.nix
      ];
    };
  };
}
```

### Service module

```nix
# my-service.nix
{ config, lib, pkgs, ... }:
let cfg = config.services.myapp;
in {
  options.services.myapp = {
    enable = lib.mkEnableOption "My application";
    domain = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
    port = lib.mkOption { type = lib.types.port; default = 8080; };
  };

  config = lib.mkIf cfg.enable {
    managedServices.myapp = {
      description = "My application";
      inherit (cfg) domain port;

      # Deployment: provide a Nix package (or slotPath for symlink-based deploys)
      deployment.package = pkgs.myapp;

      # Identity
      user = "myapp";
      stateDir = "/var/lib/myapp";

      # Security
      hardening = "standard";  # "none" | "standard" | "strict"
      openPorts = [cfg.port];

      # Systemd service (merged with framework defaults)
      service = {
        environment.NODE_ENV = "production";
        # ExecStart auto-generated from deployment.package + deployment.binName
      };
    };
  };
}
```

### Wrapper modules (no systemd service generation)

For services that wrap upstream NixOS modules (e.g. Jellyfin, Forgejo), omit `service` to skip systemd generation:

```nix
managedServices.jellyfin = {
  description = "Media streaming server";
  inherit (cfg) domain;
  openPorts = [8096 8920];
  # No service = null → no systemd.services generated
  # The upstream services.jellyfin module handles the service
};
```

### MQTT integration

Services can declare MQTT client requirements. ACLs are accumulated per-user:

```nix
# In service module A:
managedServices.sensors = {
  mqtt = { user = "iot"; acl = ["readwrite sensors/#"]; };
  # ...
};

# In service module B:
managedServices.dashboard = {
  mqtt = { user = "iot"; acl = ["read sensors/#" "readwrite dashboard/#"]; };
  # ...
};

# Result: mqtt.users.iot.acl = ["readwrite sensors/#" "read sensors/#" "readwrite dashboard/#"]
```

Enable the MQTT broker and set passwords in the host config:

```nix
mqtt.broker.enable = true;
mqtt.users.iot.passwordFile = "/run/secrets/mqtt_password";
```

## Modules

| Module | Import | Provides |
|--------|--------|----------|
| `default` | `nixosModules.default` | Everything (managed services + MQTT broker) |
| `managed-services` | `nixosModules.managed-services` | Only `managedServices.*` (no MQTT) |
| `mqtt-broker` | `nixosModules.mqtt-broker` | Only `mqtt.broker.*` and `mqtt.users.*` |

## Hardening presets

| Preset | Directives |
|--------|-----------|
| `none` | No hardening |
| `standard` | `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome`, `ReadWritePaths=[stateDir]` |
| `strict` | All of standard + `DynamicUser`, `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`, `RestrictNamespaces`, `RestrictSUIDSGID` |

## Companion modules

This module composes well with:

- **[nix-auto-proxy](https://github.com/mhhf/nix-auto-proxy)** — NGINX reverse proxy + ACME. If imported, `managedServices.*.domain` auto-generates proxy entries. Without it, proxy generation is gracefully skipped.
- **[nix-app-slot](https://github.com/mhhf/nix-app-slot)** — Symlink-based binary deployment. Use `deployment.slotPath` to point at an app slot.

Neither is required — the framework works standalone for firewall, users, hardening, and systemd generation.

## License

MIT
