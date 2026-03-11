{
  description = "Declarative self-hosted service framework for NixOS — generate infrastructure from service declarations";

  outputs = _: {
    nixosModules = {
      # Full framework: managed services + MQTT broker
      default = {imports = [./module.nix ./mqtt.nix];};

      # Individual components (for selective imports)
      managed-services = ./module.nix;
      mqtt-broker = ./mqtt.nix;
    };
  };
}
