{
  config,
  lib,
  pkgs-unstable,
  ...
}:

let
  cfg = config.systemSettings.ollama;
in
{
  options = {
    systemSettings.ollama = {
      enable = lib.mkEnableOption "serveur ollama (LLM local)";
    };
  };

  config = lib.mkIf cfg.enable {
    services.ollama = {
      enable = true;
      package = pkgs-unstable.ollama-vulkan;
      environmentVariables = {
        # Offload sur l'iGPU Arc via Vulkan. Le driver xe peut geler le compute
        # (TLB fence timeouts) : si ollama freeze à "warming up", retirer cette
        # ligne (fallback CPU) ou repasser en i915 (cf. intel-graphics).
        OLLAMA_IGPU_ENABLE = "1";
      };
    };
  };
}
