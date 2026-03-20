# nix-managed-service

**Stop writing the same NixOS boilerplate for every self-hosted service.**

Every service you deploy on NixOS needs the same infrastructure: an NGINX reverse proxy, ACME certificates, a system user, a state directory, firewall rules, a hardened systemd unit. You write it all by hand, every time, slightly differently each time.

`nix-managed-service` lets you declare a service once and generates all of that automatically.

## Before and after

Without the framework — **~40 lines of repetitive infrastructure per service:**

```nix
services.nginx.virtualHosts."app.example.com" = {
  useACMEHost = "app.example.com";
  forceSSL = true;
  locations."/".proxyPass = "http://127.0.0.1:8080";
};
security.acme.certs."app.example.com" = { dnsProvider = "gandiv5"; /* ... */ };
users.users.myapp = { isSystemUser = true; group = "myapp"; home = "/var/lib/myapp"; };
users.groups.myapp = {};
systemd.tmpfiles.rules = ["d /var/lib/myapp 0750 myapp myapp -"];
networking.firewall.allowedTCPPorts = [8080];
systemd.services.myapp = {
  wantedBy = ["multi-user.target"];
  serviceConfig = {
    ExecStart = "${pkgs.myapp}/bin/myapp";
    User = "myapp"; Group = "myapp";
    NoNewPrivileges = true; PrivateTmp = true;
    ProtectSystem = "strict"; ProtectHome = true;
    ReadWritePaths = ["/var/lib/myapp"];
    Restart = "always"; RestartSec = 10;
  };
};
```

With the framework — **one declaration, everything generated:**

```nix
managedServices.myapp = {
  domain = "app.example.com";
  port = 8080;
  user = "myapp";
  stateDir = "/var/lib/myapp";
  deployment.package = pkgs.myapp;
  service = {};
};
```

Same result. The framework generates the proxy, cert, user, group, state directory, firewall rules, and hardened systemd service — all from that single block.

## Quick start

**1. Add the flake input:**

```nix
# flake.nix
{
  inputs.nix-managed-service.url = "github:mhhf/nix-managed-service";

  outputs = { nixpkgs, nix-managed-service, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        nix-managed-service.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

**2. Configure the proxy (once per server):**

```nix
proxy = {
  listenAddress = "100.x.y.z";  # Tailscale IP, or null for all interfaces
  acme = {
    email = "you@example.com";
    dnsProvider = "cloudflare";  # any lego provider
    credentialsFile = "/run/secrets/acme-env";
  };
};
```

**3. Declare services:**

```nix
managedServices.myapp = {
  domain = "app.example.com";
  port = 8080;
  deployment.package = pkgs.myapp;
  user = "myapp";
  stateDir = "/var/lib/myapp";
  service = {};
};
```

That's it. Build with `nixos-rebuild build` and your service is running behind HTTPS with a hardened systemd unit.

## How it works

Each `managedServices.<name>` declaration is read by five cooperating modules that generate the corresponding NixOS config:

| You declare | Framework generates |
|---|---|
| `domain` | NGINX virtualHost + ACME certificate |
| `port` or `target` | Proxy upstream configuration |
| `user` | System user + group |
| `stateDir` | `tmpfiles.rules` with correct ownership |
| `openPorts` | Firewall rules |
| `service = {}` | Hardened systemd service with auto `ExecStart` |
| `deployment.slot.enable` | Deploy user, slot directory, scoped sudo |
| `healthCheck.http` | Systemd timer with auto-restart on failure |
| `mqtt` | Mosquitto ACL entries (accumulated per-user) |

If you omit an option, that piece of infrastructure is simply not generated. Set `domain` without `service` and you get a proxy with no systemd unit — perfect for wrapping upstream NixOS modules like Jellyfin or Forgejo.

## Features

### Wrapping upstream NixOS services

For services that already have a NixOS module, omit `service` — the framework only generates the infrastructure around it:

```nix
services.jellyfin.enable = true;

managedServices.jellyfin = {
  description = "Media streaming server";
  domain = "media.example.com";
  openPorts = [8096 8920];
  # service = null → no systemd unit generated, upstream handles it
};
```

### Hardening presets

Every service gets `hardening = "standard"` by default:

| Preset | Directives |
|--------|-----------|
| `none` | No hardening |
| `standard` | `NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome`, `ReadWritePaths=[stateDir]` |
| `strict` | All of standard + `DynamicUser`, `ProtectKernelTunables`, `ProtectKernelModules`, `ProtectControlGroups`, `RestrictSUIDSGID` |

Framework defaults use `mkDefault` — your overrides always win:

```nix
managedServices.myapp = {
  service = {
    serviceConfig.Restart = "on-failure";  # override framework's "always"
    after = ["postgresql.service"];         # override framework's ["network.target"]
  };
};
```

### Health checks

Declare a probe and the framework creates a systemd timer:

```nix
managedServices.myapp = {
  healthCheck = {
    http = "http://localhost:8080/health";  # or: tcp = 8080; or: exec = "mycheck";
    interval = "60s";
    onFailure = "restart";  # or "notify" (just log)
  };
};
```

### Deployment slots

For fast CI deploys (~30s) without `nixos-rebuild`, services can opt into symlink-based deployment:

```nix
# Service module:
managedServices.myapp = {
  deployment.slot.enable = true;
  deployment.binName = "myapp-server";
  service = {};
};

# Host config:
slots = {
  enable = true;
  deployKeys = ["ssh-ed25519 AAAA... ci-deploy"];
};
```

The framework creates the slot directory, a deploy user with scoped sudo (can only restart slot-enabled services), and adds the user to `nix.settings.trusted-users` for `nix copy`.

### Triggers and runners

Declare *when* a service should run and the framework generates all the systemd plumbing — timers, MQTT subscriptions, guards, and deploy oneshots. Inspired by GitHub Actions' `on:` syntax.

#### Trigger on CI pass

Run a job whenever a repo's CI succeeds (via MQTT from [pico-ci](https://github.com/mhhf/nix-pico-ci)):

```nix
managedServices.calc-benchmark = {
  on.ci = "calc";  # shorthand for: topic "git/ci/calc", filter {status: "PASS", branch: "main"}
  service.script = "cd /var/lib/src/calc && ./scripts/bench-history.sh 50";
};
```

`on.ci = "calc"` expands to an MQTT subscription on `git/ci/calc` that filters for `{status: "PASS", branch: "main"}`. A shared `trigger-mqtt.service` daemon handles all subscriptions.

To trigger on a different branch:

```nix
on.ci = { repo = "calc"; branch = "develop"; };
```

#### Trigger on schedule

Run a job on a systemd calendar schedule:

```nix
managedServices.daily-report = {
  on.schedule = "daily";
  service.script = "generate-report > /var/lib/reports/daily.html";
};
```

The framework creates a timer with `Persistent=true` (catches up after downtime) and `RandomizedDelaySec=30s` (avoids thundering herd).

#### Schedule with ifNewCommits guard

Only run if the repo has new commits since the last successful run:

```nix
managedServices.calc-benchmark = {
  on.schedule = { calendar = "daily"; ifNewCommits = "/var/lib/src/calc"; };
  service.script = "cd /var/lib/src/calc && ./scripts/bench-history.sh 50";
};
```

Uses systemd `ExecCondition` — if HEAD hasn't changed since last run, the service skips cleanly (no failure). On success, the current SHA is recorded in the service's state directory.

#### Smart defaults

Any service with `on.*` triggers automatically gets:

| Default | Value | Why |
|---------|-------|-----|
| `Type` | `oneshot` | Jobs run to completion, not as daemons |
| `Restart` | `no` | Don't restart a finished job |
| `wantedBy` | `[]` | Don't start at boot — only on trigger |
| `stateDir` | `/var/lib/jobs/<name>` | Auto-created if not set explicitly |

These use `mkOverride 900`, so explicit `service.serviceConfig` values always win.

#### Output directory and auto-commit

For jobs that produce artifacts, declare an output directory and optional auto-commit:

```nix
managedServices.calc-benchmark = {
  on.ci = "calc";
  outputDir = "/var/lib/src/hq/doc/compiled/calc";
  outputCommit = "compiled: calc benchmarks";
  service.script = "cd /var/lib/src/calc && ./scripts/bench-history.sh 50";
};
```

- `outputDir` — created automatically, available as `$OUTPUT_DIR` in the service environment, included in `ReadWritePaths` for hardened services
- `outputCommit` — after the job succeeds, stages changed files and commits with the given message (via `ExecStartPost`)

For more control over the commit:

```nix
outputCommit = {
  message = "compiled: calc benchmarks";
  repo = "/var/lib/src/hq";           # explicit repo path (default: auto-detect from outputDir)
  paths = ["doc/compiled/calc"];       # specific paths to stage (default: outputDir)
};
```

#### Concurrency groups

Serialize jobs that shouldn't run in parallel using `flock(2)`:

```nix
managedServices.calc-benchmark = {
  on.ci = "calc";
  concurrencyGroup = "heavy-jobs";
  service.script = "...";
};

managedServices.proof-checker = {
  on.ci = "proofs";
  concurrencyGroup = "heavy-jobs";  # shares the lock
  service.script = "...";
};
```

#### Raw MQTT trigger

For events beyond CI, use the MQTT escape hatch:

```nix
managedServices.light-sync = {
  on.mqtt = {
    topic = "zigbee2mqtt/light/set";
    filter = { state = "ON"; };  # optional JQ filter on payload
  };
  service.script = "...";
};
```

#### Auto-deploy on trigger

For services with deployment slots, trigger automatic builds and deploys:

```nix
managedServices.os-web = {
  domain = "os.example.com";
  deployment = {
    slot.enable = true;
    binName = "os-web";
    source = "/var/lib/src/os-web";
    buildExpr = ".#packages.x86_64-linux.default";
    on.ci = "os-web";  # auto-deploy when CI passes
  };
  service = {};
};
```

The framework generates an `os-web-deploy.service` oneshot that: builds the flake expression, rsyncs to the slot directory, restarts the service. Deploy services automatically serialize via `flock` (using `concurrencyGroup` if set, otherwise a shared `deploys` lock).

#### Combining triggers

A single service can have multiple triggers — they're independent:

```nix
managedServices.calc-benchmark = {
  on.ci = "calc";                                         # run on CI pass
  on.schedule = { calendar = "daily"; ifNewCommits = "/var/lib/src/calc"; };  # also daily
  concurrencyGroup = "heavy-jobs";
  outputDir = "/var/lib/src/hq/doc/compiled/calc";
  outputCommit = "compiled: calc benchmarks";
  service.script = "cd /var/lib/src/calc && ./scripts/bench-history.sh 50";
};
```

#### What gets generated

| You declare | Framework generates |
|---|---|
| `on.ci` | MQTT subscription + dispatch rule in `trigger-mqtt.service`, ACL for `trigger-mqtt` user |
| `on.schedule` | `trigger-<name>.timer` + `trigger-<name>.service` launcher |
| `on.schedule.ifNewCommits` | `ExecCondition` guard + SHA tracking in `ExecStartPost` |
| `on.mqtt` | Same as `on.ci` but with custom topic/filter |
| `concurrencyGroup` | `ExecStartPre` flock on `/run/lock/trigger-group-<group>.lock` |
| `outputDir` | Directory via tmpfiles, `$OUTPUT_DIR` env var, `ReadWritePaths` |
| `outputCommit` | `ExecStartPost` git add + commit |
| `deployment.on.*` | `<name>-deploy.service` oneshot (build + rsync + restart) |

### Container services

For services in NixOS containers, use `target` instead of `port`:

```nix
managedServices.bot = {
  domain = "bot.example.com";
  target = "http://10.100.0.2:8080";  # container IP
};
```

### Custom NGINX locations

For FastCGI or complex proxy configs:

```nix
managedServices.cgit = {
  domain = "git.example.com";
  locations = {
    "/" = { extraConfig = "fastcgi_pass unix:/run/fcgiwrap.sock;"; };
  };
};
```

### MQTT integration

Services declare their MQTT needs; ACLs are accumulated per-user across all services:

```nix
managedServices.sensors.mqtt = { user = "iot"; acl = ["readwrite sensors/#"]; };
managedServices.dashboard.mqtt = { user = "iot"; acl = ["read sensors/#"]; };
# → mqtt.users.iot.acl = ["readwrite sensors/#" "read sensors/#"]
```

Enable the broker in host config:

```nix
mqtt.broker.enable = true;
mqtt.users.iot.passwordFile = "/run/secrets/mqtt_password";
```

### Static sites

Host static files alongside managed services:

```nix
proxy.staticSites.blog = {
  enable = true;
  domain = "blog.example.com";
  root = "/var/www/blog";
};
```

### DNS automation

Extract DNS records from your entire fleet and push them:

```nix
# In flake.nix outputs:
apps.x86_64-linux.push_dns = nix-managed-service.lib.mkDnsPushApp {
  inherit pkgs nixosConfigurations;
  zones."example.com".provider = { type = "CLOUDFLARE"; envVar = "CF_API_TOKEN"; };
};
```

```bash
CF_API_TOKEN=xxx nix run .#push_dns
```

### Service registry

Extract metadata from all hosts for dashboards:

```nix
allServices = nix-managed-service.lib.extractServiceRegistry {
  inherit lib nixosConfigurations;
};
# → [{ name = "myapp"; domain = "app.example.com"; host = "myhost"; type = "service"; } ...]
```

## Modules

Import everything with `nixosModules.default`, or pick individual components:

| Module | Import | Provides |
|--------|--------|----------|
| `default` | `nixosModules.default` | Everything |
| `managed-services` | `nixosModules.managed-services` | Only `managedServices.*` |
| `proxy` | `nixosModules.proxy` | Only `proxy.*` (NGINX + ACME) |
| `slots` | `nixosModules.slots` | Only `slots.*` (deploy infrastructure) |
| `health-checks` | `nixosModules.health-checks` | Only health check timers |
| `mqtt-broker` | `nixosModules.mqtt-broker` | Only `mqtt.*` (Mosquitto + ACLs) |
| `triggers` | `nixosModules.triggers` | Only trigger infrastructure (`on.*`, deploy oneshots) |

## Port auto-detection

Common services have auto-detected ports — no need to specify `port`:

jellyfin (8096), grafana (3000), prometheus (9090), alertmanager (9093), transmission (9091), sonarr (8989), radarr (7878), lidarr (8686), prowlarr (9696)

## Options reference

<details>
<summary><strong>managedServices.&lt;name&gt;</strong></summary>

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `true` | Whether this managed service is active |
| `description` | nullOr str | `null` | Human-readable description |
| `domain` | nullOr str | `null` | Domain for reverse proxy (null = no proxy) |
| `port` | nullOr port | `null` | HTTP port (used for proxy target) |
| `target` | nullOr str | `null` | Explicit proxy target URL (overrides port) |
| `locations` | nullOr (attrsOf anything) | `null` | Custom NGINX location blocks |
| `publicAccess` | bool | `false` | Whether publicly accessible (all interfaces) |
| `websockets` | bool | `true` | Enable WebSocket proxying |
| `user` | nullOr str | `null` | System user to create and run as |
| `group` | nullOr str | `= user` | System group |
| `stateDir` | nullOr str | `null` | Persistent state directory |
| `hardening` | enum | `"standard"` | `"none"`, `"standard"`, `"strict"` |
| `openPorts` | listOf port | `[]` | TCP firewall ports |
| `openUDPPorts` | listOf port | `[]` | UDP firewall ports |
| `serviceName` | str | `<name>` | Systemd unit name |
| `service` | nullOr attrs | `null` | Systemd service definition (null = skip) |
| `deployment.package` | nullOr package | `null` | Nix package providing the binary |
| `deployment.binName` | str | `<name>` | Binary name in package's bin/ |
| `deployment.slotPath` | nullOr str | *(auto)* | Slot path (auto-computed when slot.enable) |
| `deployment.slot.enable` | bool | `false` | Enable deployment slot |
| `deployment.slot.restartUnit` | str | `<serviceName>` | Unit to restart after deploy |
| `binaryPath` | nullOr str | *(computed)* | Resolved binary path (read-only) |
| `healthCheck.http` | nullOr str | `null` | HTTP URL to check |
| `healthCheck.tcp` | nullOr port | `null` | TCP port to check |
| `healthCheck.exec` | nullOr str | `null` | Command to run |
| `healthCheck.interval` | str | `"60s"` | Check interval |
| `healthCheck.timeoutSec` | int | `10` | Timeout in seconds |
| `healthCheck.onFailure` | enum | `"notify"` | `"restart"` or `"notify"` |
| `on.ci` | nullOr (str or {repo, branch}) | `null` | CI trigger — string is repo name shorthand |
| `on.schedule` | nullOr (str or {calendar, ifNewCommits}) | `null` | Schedule trigger — string is calendar shorthand |
| `on.mqtt` | nullOr {topic, filter} | `null` | Raw MQTT trigger |
| `concurrencyGroup` | nullOr str | `null` | Serialize via flock with other services in same group |
| `outputDir` | nullOr str | `null` | Output directory (auto-created, `$OUTPUT_DIR` env) |
| `outputCommit` | nullOr (str or {message, repo, paths}) | `null` | Auto-commit after success |
| `deployment.on.ci` | nullOr (str or {repo, branch}) | `null` | CI trigger for auto-deploy |
| `deployment.on.schedule` | nullOr str | `null` | Schedule trigger for auto-deploy |
| `deployment.on.mqtt` | nullOr {topic, filter} | `null` | MQTT trigger for auto-deploy |
| `deployment.source` | nullOr str | `null` | Source directory for auto-deploy builds |
| `deployment.buildExpr` | str | `".#default"` | Nix build expression for auto-deploy |
| `mqtt.user` | str | — | MQTT username |
| `mqtt.acl` | listOf str | `[]` | MQTT ACL rules |

</details>

<details>
<summary><strong>proxy</strong></summary>

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `proxy.listenAddress` | nullOr str | `null` | IP for private services (e.g. Tailscale) |
| `proxy.publicAddress` | nullOr str | `null` | Public IP (for DNS extraction) |
| `proxy.acme.email` | str | `""` | ACME account email |
| `proxy.acme.dnsProvider` | str | `"gandiv5"` | DNS-01 provider (lego name) |
| `proxy.acme.credentialsFile` | nullOr path | `null` | Provider credentials file |

**proxy.services.\<name\>** (auto-populated from `managedServices`):

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | — | Enable reverse proxy |
| `domain` | str | — | Domain name |
| `port` | nullOr port | `null` | Port (auto-detected for common services) |
| `target` | nullOr str | `null` | Custom proxy target URL |
| `websockets` | bool | `true` | WebSocket support |
| `publicAccess` | bool | `false` | All interfaces vs listenAddress |
| `locations` | attrsOf anything | `{}` | Custom NGINX locations |

**proxy.staticSites.\<name\>**:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | — | Enable static site |
| `domain` | str | — | Domain name |
| `root` | str | — | Root directory |
| `createDirectory` | bool | `true` | Auto-create root directory |
| `publicAccess` | bool | `false` | All interfaces |

</details>

<details>
<summary><strong>slots</strong></summary>

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `slots.enable` | bool | `false` | Enable deployment slot infrastructure |
| `slots.baseDir` | str | `"/srv/apps"` | Base directory for app slots |
| `slots.deployUser` | str | `"deploy"` | Deployment user name |
| `slots.deployKeys` | listOf str | `[]` | SSH public keys for deploy user |
| `slots.trustedUser` | bool | `true` | Add deploy user to nix trusted-users |

</details>

<details>
<summary><strong>mqtt</strong></summary>

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `mqtt.broker.enable` | bool | `false` | Enable Mosquitto broker |
| `mqtt.broker.port` | port | `1883` | Listener port |
| `mqtt.broker.address` | str | `"127.0.0.1"` | Bind address |
| `mqtt.users.<name>.acl` | listOf str | `[]` | ACL rules (auto-accumulated) |
| `mqtt.users.<name>.passwordFile` | nullOr path | `null` | Password file |
| `mqtt.host` | str | *(read-only)* | Broker hostname for clients |
| `mqtt.port` | port | *(read-only)* | Broker port for clients |

</details>

## License

MIT
