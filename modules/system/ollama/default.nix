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
        # (ZES_ENABLE_SYSMAN retiré : variable oneAPI / Level Zero, donc du
        # chemin SYCL. Elle n'apparaît nulle part dans les sources
        # d'ollama-vulkan — c'était un vestige sans effet sur ce backend.)

        # Offload the model to the Arc iGPU via Vulkan. NOTE: the `xe` driver can
        # intermittently hang GPU compute on this Meteor Lake (TLB invalidation
        # fence timeouts) — if ollama freezes at "warming up", remove this line to
        # fall back to CPU, or switch the GPU from xe -> i915 for stability
        # (cf. modules/system/intel-graphics).
        OLLAMA_IGPU_ENABLE = "1";
      };
    };
  };
}
