{
  description = "Unified self-hosted service framework: declarative service infrastructure generation";

  outputs = _: {
    nixosModules.default = {imports = [./module.nix ./mqtt.nix];};
  };
}
