{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.userSettings.ssh;
in
{
  options.userSettings.ssh = {
    waypipe.enable = lib.mkEnableOption ''
      la commande `wssh` (ssh via waypipe) : le presse-papier Wayland local est
      lisible à distance par `wl-paste`, sans X11 ni accès aux autres fenêtres
    '';

    hosts = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
      example = lib.literalExpression ''
        {
          serveur = {
            HostName = "192.168.1.32";
            Port = 3249;
            User = "moi";
          };
        }
      '';
      description = ''
        Blocs de `programs.ssh.settings` : la clé est le motif `Host`, les
        attributs portent les noms d'options OpenSSH (`HostName`, `Port`, `User`).
        Préférer une adresse à un nom pour une machine à adresse statique.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.hosts != { }) {
      programs.ssh = {
        enable = true;
        settings = cfg.hosts;

        enableDefaultConfig = false;
      };
    })

    # --no-gpu : un serveur sans GPU fait échouer waypipe à l'init de Vulkan.
    (lib.mkIf cfg.waypipe.enable {
      home.packages = [
        (pkgs.writeShellApplication {
          name = "wssh";
          runtimeInputs = [ pkgs.waypipe ];
          text = ''exec waypipe --no-gpu ssh "$@"'';
        })
      ];
    })
  ];
}
