# MQTT broker with auto-generated ACLs from managed services
#
# Provides a managed Mosquitto broker where users and ACL rules
# are declaratively accumulated from service modules.
#
# Usage:
#   mqtt.broker = { enable = true; };
#   mqtt.users.myuser.passwordFile = "/run/secrets/mqtt_password";
#
# Managed services auto-contribute ACL entries:
#   managedServices.sensorhub.mqtt = { user = "iot"; acl = ["readwrite sensors/#"]; };
#   managedServices.dashboard.mqtt = { user = "iot"; acl = ["readwrite dashboard/#"]; };
#   → mqtt.users.iot.acl = ["readwrite sensors/#" "readwrite dashboard/#"];
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
        description = "Mosquitto ACL rules (e.g. 'readwrite sensors/#', 'read status/#').";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing the plain-text MQTT password. null if set elsewhere or not needed.";
      };
    };
  };
in {
  options.mqtt = {
    broker = {
      enable = lib.mkEnableOption "Managed MQTT broker (Mosquitto)";

      port = lib.mkOption {
        type = lib.types.port;
        default = 1883;
        description = "MQTT listener port.";
      };

      address = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Address to bind the MQTT listener to.";
      };

      maxQueuedMessages = lib.mkOption {
        type = lib.types.int;
        default = 10000;
        description = "Maximum number of queued messages per client.";
      };

      extraSettings = lib.mkOption {
        type = lib.types.attrs;
        default = {};
        description = "Additional Mosquitto settings merged into the listener config.";
      };
    };

    users = lib.mkOption {
      type = lib.types.attrsOf userModule;
      default = {};
      description = ''
        MQTT user declarations. Each user becomes a Mosquitto user with ACL rules.
        Managed services auto-contribute ACL entries via managedServices.*.mqtt.
      '';
    };

    # Connection info for service modules (auto-derived from broker, or set manually for remote brokers)
    host = lib.mkOption {
      type = lib.types.str;
      default =
        if brokerCfg.address == "0.0.0.0" || brokerCfg.address == "::"
        then "localhost"
        else brokerCfg.address;
      description = "MQTT broker hostname for service modules to connect to. Auto-derived from broker.address when using local broker. Set manually for remote brokers.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = brokerCfg.port;
      description = "MQTT broker port (for service modules to reference). Auto-derived from broker.port when using local broker.";
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
            lib.mapAttrs (
              _name: userCfg:
                {inherit (userCfg) acl;}
                // lib.optionalAttrs (userCfg.passwordFile != null) {
                  inherit (userCfg) passwordFile;
                }
            )
            cfg.users;
        }
      ];
    };
  };
}
