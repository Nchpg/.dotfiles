{
  config,
  lib,
  ...
}:

# Client SSH : des raccourcis pour les machines qu'on administre.
#
# Passe-plat assumé vers `programs.ssh.settings` de home-manager, dont le schéma
# est déjà déclaratif : le redécrire ici n'apporterait qu'une couche à maintenir,
# et il faudrait la retoucher à chaque option OpenSSH qu'on veut atteindre. Ce
# module existe pour que les profils continuent de ne parler que `userSettings`,
# comme partout ailleurs.
let
  cfg = config.userSettings.ssh;
in
{
  options.userSettings.ssh = {
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
        Blocs du fichier de configuration SSH, tels que les attend
        `programs.ssh.settings`. La clé est le motif `Host`, donc le nom qu'on
        tape : `ssh serveur`.

        Les attributs portent les noms d'options d'OpenSSH — `HostName`, `Port`,
        `User` — et non les noms en minuscules de l'ancien `matchBlocks`, que
        home-manager a déprécié.

        Préférer une ADRESSE à un nom pour une machine dont l'adresse est
        statique : l'alias sert justement les jours où la résolution ne marche
        plus, et un nom y ajouterait la dépendance qu'on cherche à éviter.
      '';
    };
  };

  config = lib.mkIf (cfg.hosts != { }) {
    programs.ssh = {
      enable = true;
      settings = cfg.hosts;

      # home-manager écrit sinon un bloc `Host *` et prévient que c'est déprécié.
      # Rien à conserver : les dix valeurs qu'il y met — ForwardAgent no,
      # Compression no, ControlMaster no… — sont précisément les défauts
      # d'OpenSSH, donc les inscrire ne change rien sinon ajouter du bruit dans
      # ~/.ssh/config. Coupé, le fichier ne contient plus que les hôtes déclarés.
      enableDefaultConfig = false;
    };
  };
}
