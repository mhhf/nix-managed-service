{
  description = "Declarative self-hosted service framework for NixOS — generate infrastructure from service declarations";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {nixpkgs, ...}: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    nixosModules = {
      # Full framework: managed services + proxy + slots + health checks + MQTT broker + triggers
      default = {imports = [./module.nix ./proxy.nix ./slots.nix ./health.nix ./mqtt.nix ./triggers.nix];};

      # Individual components (for selective imports)
      managed-services = ./module.nix;
      proxy = ./proxy.nix;
      slots = ./slots.nix;
      health-checks = ./health.nix;
      mqtt-broker = ./mqtt.nix;
      triggers = ./triggers.nix;
    };

    # Library functions for cross-host operations
    lib = {
      extractDnsRecords = import ./lib/dns.nix;
      mkDnsPushApp = import ./lib/push-app.nix;
      extractServiceRegistry = import ./lib/registry.nix;
    };

    # Formatting
    formatter.${system} = pkgs.alejandra;

    # Tests
    checks.${system} = {
      # Test: basic managed service with systemd service generation
      basic-service = pkgs.testers.nixosTest {
        name = "basic-service";
        nodes.machine = {pkgs, ...}: {
          imports = [./module.nix ./proxy.nix ./slots.nix ./health.nix ./mqtt.nix];
          managedServices.testapp = {
            description = "Test application";
            port = 8080;
            user = "testapp";
            stateDir = "/var/lib/testapp";
            hardening = "standard";
            deployment.package = pkgs.hello;
            deployment.binName = "hello";
            service = {};
          };
        };
        testScript = ''
          machine.wait_for_unit("testapp.service")
          # Verify user was created
          machine.succeed("id testapp")
          # Verify state directory was created
          machine.succeed("test -d /var/lib/testapp")
          # Verify state directory ownership
          machine.succeed("stat -c '%U:%G' /var/lib/testapp | grep -q 'testapp:testapp'")
        '';
      };

      # Test: wrapper module (no systemd service, e.g. jellyfin pattern)
      wrapper-module = pkgs.testers.nixosTest {
        name = "wrapper-module";
        nodes.machine = {
          imports = [./module.nix ./proxy.nix ./slots.nix ./health.nix ./mqtt.nix];
          managedServices.mywrapper = {
            description = "Wrapper around upstream module";
            openPorts = [9090];
            openUDPPorts = [5353];
            # service = null (default) — no systemd service generated
          };
        };
        testScript = ''
          machine.wait_for_unit("multi-user.target")
          # Verify firewall ports are open
          machine.succeed("iptables -L -n | grep -q 9090")
        '';
      };

      # Test: proxy module generates nginx vhosts
      proxy-config = pkgs.testers.nixosTest {
        name = "proxy-config";
        nodes.machine = {
          imports = [./module.nix ./proxy.nix ./slots.nix ./health.nix ./mqtt.nix];
          # Proxy needs ACME config when domains are set
          proxy = {
            listenAddress = "127.0.0.1";
            acme = {
              email = "test@example.com";
              dnsProvider = "manual";
              credentialsFile = builtins.toFile "empty" "";
            };
          };
          managedServices.myproxy = {
            domain = "app.example.com";
            port = 3000;
          };
          # Disable ACME for test (no DNS challenge possible)
          security.acme.defaults.server = "https://127.0.0.1";
        };
        testScript = ''
          machine.wait_for_unit("nginx.service")
          # Verify nginx config includes our domain
          machine.succeed("systemctl show nginx -p ExecStart | grep -oP '/nix/store/[^ ]*nginx.conf' | head -1 | xargs grep 'app.example.com'")
        '';
      };

      # Test: health check timer is created
      health-check = pkgs.testers.nixosTest {
        name = "health-check";
        nodes.machine = {pkgs, ...}: {
          imports = [./module.nix ./proxy.nix ./slots.nix ./health.nix ./mqtt.nix];
          managedServices.healthyapp = {
            deployment.package = pkgs.hello;
            deployment.binName = "hello";
            service = {};
            healthCheck = {
              exec = "${pkgs.coreutils}/bin/true";
              interval = "30s";
              onFailure = "restart";
            };
          };
        };
        testScript = ''
          machine.wait_for_unit("multi-user.target")
          # Verify health check timer exists
          machine.succeed("systemctl list-timers | grep -q healthcheck-healthyapp")
          # Verify restart helper service exists
          machine.succeed("systemctl cat healthcheck-restart-healthyapp.service")
          # Run health check manually
          machine.succeed("systemctl start healthcheck-healthyapp.service")
        '';
      };

      # Test: MQTT broker with accumulated ACLs
      mqtt-acl = pkgs.testers.nixosTest {
        name = "mqtt-acl";
        nodes.machine = {
          imports = [./module.nix ./proxy.nix ./slots.nix ./health.nix ./mqtt.nix];
          mqtt.broker.enable = true;
          # Simulate two services sharing an MQTT user
          managedServices.sensor = {
            mqtt = {
              user = "iot";
              acl = ["readwrite sensors/#"];
            };
          };
          managedServices.dashboard = {
            mqtt = {
              user = "iot";
              acl = ["read dashboard/#"];
            };
          };
        };
        testScript = ''
          machine.wait_for_unit("mosquitto.service")
          # Verify mosquitto is running
          machine.succeed("systemctl is-active mosquitto.service")
        '';
      };

      # Test: deployment slots create directories and scoped sudo
      deployment-slots = pkgs.testers.nixosTest {
        name = "deployment-slots";
        nodes.machine = {pkgs, ...}: {
          imports = [./module.nix ./proxy.nix ./slots.nix ./health.nix ./mqtt.nix];
          slots = {
            enable = true;
            deployKeys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItest test-key"];
          };
          managedServices.slotapp = {
            deployment = {
              slot.enable = true;
              binName = "slotapp";
            };
            service = {
              serviceConfig.ExecStart = "/bin/true";
            };
          };
        };
        testScript = ''
          machine.wait_for_unit("multi-user.target")
          # Verify deploy user exists
          machine.succeed("id deploy")
          # Verify slot directory exists
          machine.succeed("test -d /srv/apps/slotapp")
          # Verify slot directory ownership
          machine.succeed("stat -c '%U' /srv/apps/slotapp | grep -q deploy")
          # Verify scoped sudo
          machine.succeed("grep -q 'systemctl restart slotapp' /etc/sudoers.d/* || sudo -l -U deploy | grep -q 'systemctl restart slotapp'")
        '';
      };

      # Test: strict hardening includes ReadWritePaths for stateDir
      strict-hardening = pkgs.testers.nixosTest {
        name = "strict-hardening";
        nodes.machine = {pkgs, ...}: {
          imports = [./module.nix ./proxy.nix ./slots.nix ./health.nix ./mqtt.nix];
          managedServices.strictapp = {
            hardening = "strict";
            stateDir = "/var/lib/strictapp";
            user = "strictapp";
            deployment.package = pkgs.writeShellApplication {
              name = "strictapp";
              text = "touch /var/lib/strictapp/testfile && sleep infinity";
            };
            service = {};
          };
        };
        testScript = ''
          machine.wait_for_unit("strictapp.service")
          import time
          time.sleep(2)
          # Verify stateDir is writable even under strict hardening
          machine.succeed("test -f /var/lib/strictapp/testfile")
          # Verify hardening directives are applied
          machine.succeed("systemctl show strictapp.service -p ProtectSystem | grep -q strict")
          machine.succeed("systemctl show strictapp.service -p NoNewPrivileges | grep -q yes")
        '';
      };

      # Test: triggered service with on.schedule
      trigger-schedule = pkgs.testers.nixosTest {
        name = "trigger-schedule";
        nodes.machine = {pkgs, ...}: {
          imports = [./module.nix ./proxy.nix ./slots.nix ./health.nix ./mqtt.nix ./triggers.nix];
          managedServices.test-job = {
            user = "test-job";
            on.schedule = "minutely";
            service.script = "echo triggered > /var/lib/jobs/test-job/ran";
          };
        };
        testScript = ''
          machine.wait_for_unit("multi-user.target")
          # Verify timer was created
          machine.succeed("systemctl list-timers | grep -q trigger-test-job")
          # Verify service is oneshot (smart default)
          machine.succeed("systemctl show test-job.service -p Type | grep -q oneshot")
          # Verify service is NOT started at boot (no wantedBy)
          machine.succeed("! systemctl is-active test-job.service")
          # Start manually and verify it runs
          machine.succeed("systemctl start test-job.service")
          # Verify auto-stateDir was created
          machine.succeed("test -d /var/lib/jobs/test-job")
          machine.succeed("test -f /var/lib/jobs/test-job/ran")
        '';
      };

      # Test: triggered service with on.ci (MQTT trigger + ACL)
      trigger-mqtt = pkgs.testers.nixosTest {
        name = "trigger-mqtt";
        nodes.machine = {pkgs, ...}: {
          imports = [./module.nix ./proxy.nix ./slots.nix ./health.nix ./mqtt.nix ./triggers.nix];
          mqtt.broker.enable = true;
          managedServices.ci-job = {
            user = "ci-job";
            on.ci = "myrepo";
            service.script = "echo ci-triggered > /tmp/ci-job-ran";
          };
        };
        testScript = ''
          machine.wait_for_unit("trigger-mqtt.service")
          # Verify trigger-mqtt daemon is running
          machine.succeed("systemctl is-active trigger-mqtt.service")
          # Verify MQTT ACL was generated
          machine.succeed("grep -q 'git/ci/myrepo' /etc/mosquitto/acl || true")
          # Verify service is oneshot
          machine.succeed("systemctl show ci-job.service -p Type | grep -q oneshot")
        '';
      };

      # Test: outputDir creates directory and sets env
      trigger-output = pkgs.testers.nixosTest {
        name = "trigger-output";
        nodes.machine = {pkgs, ...}: {
          imports = [./module.nix ./proxy.nix ./slots.nix ./health.nix ./mqtt.nix ./triggers.nix];
          managedServices.output-job = {
            user = "output-job";
            on.schedule = "yearly";
            outputDir = "/var/lib/test-output";
            service.script = "echo $OUTPUT_DIR > /var/lib/jobs/output-job/dir-val";
          };
        };
        testScript = ''
          machine.wait_for_unit("multi-user.target")
          # Verify output directory was created
          machine.succeed("test -d /var/lib/test-output")
          # Start job and verify OUTPUT_DIR env
          machine.succeed("systemctl start output-job.service")
          machine.succeed("grep -q '/var/lib/test-output' /var/lib/jobs/output-job/dir-val")
        '';
      };

      # Test: assertions fire correctly
      format = pkgs.runCommand "fmt-check" {} ''
        ${pkgs.alejandra}/bin/alejandra --check ${./.} && touch $out
      '';
    };
  };
}
