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
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-managed-service.url = "github:mhhf/nix-managed-service";
  };

  outputs = { nixpkgs, nix-managed-service, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
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

### Custom scripts and computed paths

The framework computes `binaryPath` from your deployment config. Reference it in custom scripts:

```nix
managedServices.myapp = {
  deployment = { inherit (cfg) slotPath package; binName = "myapp-server"; };
  service.script = ''
    export CONFIG_DIR=${cfg.stateDir}/config
    exec ${config.managedServices.myapp.binaryPath} --port ${toString cfg.port}
  '';
};
```

### Overriding framework defaults

Framework defaults use `mkDefault`, so your overrides win naturally:

```nix
managedServices.myapp = {
  service = {
    # Override restart policy (framework default: Restart=always)
    serviceConfig.Restart = "on-failure";
    # Override target (framework default: wantedBy multi-user.target)
    wantedBy = ["network-online.target"];
    after = ["network-online.target" "postgresql.service"];
  };
};
```

### Container services

For services running in NixOS containers, use `target` instead of `port`:

```nix
managedServices.myapp = {
  description = "Containerized service";
  inherit (cfg) domain;
  target = "http://10.100.0.2:8080";  # Container IP
};
```

### Custom NGINX locations

For services needing FastCGI or complex NGINX config, use `locations`:

```nix
managedServices.cgit = {
  inherit (cfg) domain;
  locations = {
    "~ ^/([^/]+)/(info/refs|git-upload-pack)$" = {
      fastcgi_pass = "unix:/run/fcgiwrap.sock";
    };
    "/" = { root = staticDir; tryFiles = "$uri @cgit"; };
  };
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

## Options reference

### `managedServices.<name>`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `true` | Whether this managed service is active |
| `description` | nullOr str | `null` | Human-readable description |
| `domain` | nullOr str | `null` | Domain for reverse proxy (null = no proxy) |
| `port` | nullOr port | `null` | HTTP port (used for proxy target) |
| `target` | nullOr str | `null` | Explicit proxy target URL (overrides port) |
| `locations` | nullOr (attrsOf anything) | `null` | Custom NGINX location blocks |
| `publicAccess` | bool | `false` | Whether publicly accessible (passed to proxy) |
| `websockets` | bool | `true` | Whether to enable WebSocket proxying |
| `deployment.slotPath` | nullOr str | `null` | Symlink-based deployment slot path |
| `deployment.package` | nullOr package | `null` | Nix package providing the binary |
| `deployment.binName` | str | `<name>` | Binary name in package's bin/ directory |
| `binaryPath` | nullOr str | *(computed)* | Resolved binary path (read-only) |
| `user` | nullOr str | `null` | System user to create and run as |
| `group` | nullOr str | `= user` | System group |
| `stateDir` | nullOr str | `null` | Persistent state directory |
| `hardening` | enum | `"standard"` | Hardening preset: `"none"`, `"standard"`, `"strict"` |
| `openPorts` | listOf port | `[]` | TCP firewall ports |
| `openUDPPorts` | listOf port | `[]` | UDP firewall ports |
| `mqtt.user` | str | — | MQTT username (ACLs merged across services) |
| `mqtt.acl` | listOf str | `[]` | MQTT ACL rules |
| `serviceName` | str | `<name>` | Systemd unit name |
| `service` | nullOr attrs | `null` | Systemd service definition (null = no service) |

### `mqtt.broker`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable managed Mosquitto broker |
| `port` | port | `1883` | Listener port |
| `address` | str | `"127.0.0.1"` | Bind address |
| `maxQueuedMessages` | int | `10000` | Max queued messages per client |
| `extraSettings` | attrs | `{}` | Additional Mosquitto settings |

### `mqtt.users.<name>`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `acl` | listOf str | `[]` | ACL rules (auto-accumulated from managed services) |
| `passwordFile` | nullOr path | `null` | Path to plain-text password file |

### `mqtt.host` / `mqtt.port` (read-only)

Connection info for service modules. `mqtt.host` auto-derives from `broker.address` (wildcard addresses resolve to `localhost`).

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
