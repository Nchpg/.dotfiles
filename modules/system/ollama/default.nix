{
  config,
  lib,
  pkgs-unstable,
  ...
}:

let
  cfg = config.systemSettings.ollama;

  # Le socket systemd tient le port public (défaut du client) ; le serveur écoute à côté.
  publicPort = 11434;
  backendPort = 11435;
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
      port = backendPort;
      package = pkgs-unstable.ollama-vulkan;
      environmentVariables = {
        # Si ollama gèle à "warming up" (driver xe), retirer cette ligne ou repasser en i915.
        OLLAMA_IGPU_ENABLE = "1";
      };
    };

    systemd.services.ollama = {
      wantedBy = lib.mkForce [ ];
      unitConfig.StopWhenUnneeded = true;
      serviceConfig.ExecStartPost = pkgs-unstable.writeShellScript "ollama-wait-ready" ''
        for _ in $(seq 1 100); do
          (exec 3<>/dev/tcp/127.0.0.1/${toString backendPort}) 2>/dev/null && exit 0
          sleep 0.1
        done
        exit 1
      '';
    };

    systemd.sockets.ollama-proxy = {
      wantedBy = [ "sockets.target" ];
      listenStreams = [ "127.0.0.1:${toString publicPort}" ];
    };

    systemd.services.ollama-proxy = {
      requires = [ "ollama.service" ];
      after = [ "ollama.service" ];
      serviceConfig.ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd --exit-idle-time=15min 127.0.0.1:${toString backendPort}";
    };
  };
}
