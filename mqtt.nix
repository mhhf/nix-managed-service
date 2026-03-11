# MQTT broker with auto-generated ACLs from managed services
#
# mqtt.broker = { enable = true; };
# mqtt.users.automation.passwordFile = "/run/secrets/mqtt_password";
#
# Managed services contribute ACL entries:
#   managedServices.autohome.mqtt = { user = "automation"; acl = ["readwrite home/#"]; };
#   managedServices.zigbee2mqtt.mqtt = { user = "automation"; acl = ["readwrite zigbee2mqtt/#"]; };
#   → mqtt.users.automation.acl = ["readwrite home/#" "readwrite zigbee2mqtt/#"];
{
  config,
  lib,
  ...
}: let
  cfg = config.mqtt;
  brokerCfg = cfg.broker;

  userModule = lib.types.submodule {
    options = {
      acl = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        description = "ACL rules (e.g. 'readwrite home/#')";
      };
      passwordFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing the MQTT password";
      };
    };
  };
in {
  options.mqtt = {
    broker = {
      enable = lib.mkEnableOption "Managed MQTT broker (mosquitto)";

      port = lib.mkOption {
        type = lib.types.port;
        default = 1883;
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = "0.0.0.0";
      };

      maxQueuedMessages = lib.mkOption {
        type = lib.types.int;
        default = 10000;
      };

      extraSettings = lib.mkOption {
        type = lib.types.attrs;
        default = {};
      };
    };

    users = lib.mkOption {
      type = lib.types.attrsOf userModule;
      default = {};
      description = ''
        MQTT user declarations. Each user becomes a mosquitto user with ACL rules.
        Managed services auto-contribute ACL entries via managedServices.*.mqtt.
      '';
    };

    # Read-only connection info for service modules
    host = lib.mkOption {
      type = lib.types.str;
      default = "localhost";
      readOnly = true;
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = brokerCfg.port;
      readOnly = true;
    };
  };

  config = lib.mkIf brokerCfg.enable {
    services.mosquitto = {
      enable = true;
      settings =
        {max_queued_messages = brokerCfg.maxQueuedMessages;}
        // brokerCfg.extraSettings;
      listeners = [
        {
          inherit (brokerCfg) address port;
          users =
            lib.mapAttrs (_name: userCfg: {
              inherit (userCfg) acl passwordFile;
            })
            cfg.users;
        }
      ];
    };
  };
}
