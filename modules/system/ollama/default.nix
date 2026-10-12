{
  config,
  lib,
  pkgs-unstable,
  ...
}:

let
  cfg = config.systemSettings.ollama;

  # Port public (celui que vise le client `ollama` par défaut) tenu par un
  # socket systemd ; le vrai serveur écoute à côté, lancé au premier appel.
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
        # Offload sur l'iGPU Arc via Vulkan. Le driver xe peut geler le compute
        # (TLB fence timeouts) : si ollama freeze à "warming up", retirer cette
        # ligne (fallback CPU) ou repasser en i915 (cf. intel-graphics).
        OLLAMA_IGPU_ENABLE = "1";
      };
    };

    # Démarré à la demande plutôt qu'au boot : le socket écoute sur le port
    # public, le proxy lance ollama au premier appel et s'arrête après 15 min
    # sans connexion, ce qui arrête ollama avec lui (StopWhenUnneeded).
    systemd.services.ollama = {
      wantedBy = lib.mkForce [ ];
      unitConfig.StopWhenUnneeded = true;
      # Le proxy relaie dès que ollama est « démarré » : attendre que le port
      # réponde vraiment, sinon la première requête tombe dans le vide.
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
