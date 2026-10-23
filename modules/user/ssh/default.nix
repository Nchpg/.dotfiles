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
    waypipe.hosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "serveur" ];
      description = ''
        Hôtes (alias ou adresse) pour lesquels la fonction fish `ssh` passe par
        waypipe : le presse-papier Wayland local y est lisible par `wl-paste`
        (Ctrl+V d'image dans Claude Code). L'hôte doit avoir waypipe
        (systemSettings.ssh.waypipe). git, scp et VS Code appellent le binaire
        et ne sont pas concernés.
      '';
    };

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

    # L'hôte est le premier argument hors option ; les lettres listées
    # consomment l'argument suivant (cf. ssh(1)).
    # --no-gpu : un serveur sans GPU fait échouer waypipe à l'init de Vulkan.
    (lib.mkIf (cfg.waypipe.hosts != [ ]) {
      programs.fish.functions.ssh = ''
        set -l host
        set -l skip 0
        for arg in $argv
            if test $skip = 1
                set skip 0
                continue
            end
            switch $arg
                case '-*'
                    if contains -- (string sub -s -1 -- $arg) B b c D E e F I i J L l m O o P p Q R S W w
                        set skip 1
                    end
                case '*'
                    set host (string replace -r '^.*@' "" -- $arg)
                    break
            end
        end

        if set -q WAYLAND_DISPLAY; and contains -- "$host" ${lib.escapeShellArgs cfg.waypipe.hosts}
            ${lib.getExe pkgs.waypipe} --no-gpu ssh $argv
        else
            command ssh $argv
        end
      '';
    })
  ];
}
