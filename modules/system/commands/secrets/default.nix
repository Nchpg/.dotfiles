{
  config,
  pkgs-stable,
  target,
  lib,
  myLib,
  ...
}:

# Accès aux secrets sops, des deux côtés de la frontière posée par
# modules/system/sops : les secrets SYSTÈME ne se déchiffrent qu'en root, les
# tiens avec ta clé age.
#
# Raison d'être, en deux temps.
#
# L'invocation correcte pour les secrets système est imprononçable : la bonne
# clé, et surtout des chemins ABSOLUS. `sops` et `nvim` ne sont installés que
# dans le profil home-manager de l'utilisateur, donc `sudo sops` échoue en
# « command not found » — root ne les a pas dans son PATH.
#
# Ces chemins sont figés AU BUILD, jamais résolus depuis ton environnement, et
# c'est une propriété de sécurité et non de commodité. Tout ce que cette
# commande passe à sudo s'exécute en root : un binaire choisi à l'exécution via
# $EDITOR ou via ton PATH rendait root à n'importe quel code tournant sous ton
# compte, qui n'avait qu'à attendre le prochain `secrets`. Ça annulait toute la
# frontière que modules/system/sops construit, et dont la raison d'être est
# précisément qu'un agent ou un prebuild npm ne lise pas les secrets des
# services.
#
# `env` plutôt que `sudo VAR=... commande` : les deux marchent ici, les règles
# sudo de NixOS accordant SETENV par défaut, mais `env` reste lisible et ne
# dépend pas de ce réglage.
#
# Et depuis que les valeurs vivent dans un dépôt PRIVÉ à part (cf. l'entrée
# `secrets` de flake.nix), une modification demande DEUX commits : un ici pour
# la valeur, un là-bas pour bouger le lock. Oublier le second, c'est croire
# qu'on a fait tourner un secret alors que les machines déploient toujours
# l'ancien. Cette commande enchaîne les deux.
{
  # Entrée du catalogue de `dots` (cf. ../default.nix).
  systemSettings.commands.secrets = {
    desc = "édite et audite les secrets sops (dépôt privé)";
    order = 5;
    examples = [
      [
        "secrets list"
        "liste les secrets (aucun déchiffrement)"
      ]
      [
        "secrets show <clé>"
        "affiche une valeur, ex. gh/token"
      ]
      [
        "secrets edit <clé>"
        "édite ou crée un secret, puis synchronise"
      ]
      [
        "secrets policy"
        "régénère les règles sops, rescelle, synchronise"
      ]
      [
        "secrets status"
        "dépôt privé en phase avec le lock ?"
      ]
      [
        "secrets sync"
        "commit + push du dépôt privé, mise à jour du lock"
      ]
    ];
  };

  environment.systemPackages = [
    (pkgs-stable.writeShellApplication {
      name = "secrets";
      runtimeInputs = [
        pkgs-stable.sops
        pkgs-stable.coreutils
        pkgs-stable.git
        # `find` et `sed`, que `list` et le rescellement emploient pour parcourir
        # l'arborescence des secrets. Déclarés, et pas laissés au PATH ambiant :
        # c'est toute la raison d'être de ce bloc, et un `find` pris ailleurs
        # serait un binaire choisi à l'exécution dans une commande dont une
        # partie s'exécute sous sudo.
        pkgs-stable.findutils
        pkgs-stable.gnused
        # `grep` et `awk` aussi : forUser, forRoot, misSealed.
        pkgs-stable.gnugrep
        pkgs-stable.gawk
        # Pour relever TA clé publique et savoir, fichier par fichier, si tu en
        # es destinataire — donc s'il faut passer par root ou non.
        pkgs-stable.age
        # Lecture de la révision épinglée dans flake.lock (`status`, `sync`,
        # hooks git).
        pkgs-stable.jq
      ];
      # Le script lui-même : secrets.sh, à côté. Seules les valeurs figées au
      # build viennent d'ici, en préambule.
      text = ''
        ${myLib.flakeVar}
        # Ancre de la clé système de CETTE machine dans le .sops.yaml : c'est
        # par elle qu'on sait, sans sudo, si root ouvrira un fichier (la clé
        # privée est en 0600 root).
        sysAnchor="${target.host}-sys"

        # `nix` n'est pas dans runtimeInputs, et le résoudre depuis ton PATH
        # revenait à laisser choisir le binaire que `sudo` allait exécuter
        # dans sync(). Celui du système, pas un autre : c'est lui qui écrit le
        # lock.
        nixBin=${config.nix.package}/bin/nix

        # ÉDITEUR FIGÉ AU BUILD, jamais lu depuis $EDITOR. C'est sops, lancé
        # par sudo, qui l'exécute : le résoudre à l'exécution suffisait à
        # obtenir root en posant `EDITOR=/tmp/x` dans un fichier de démarrage
        # du shell.
        #
        # `--clean` en plus du chemin du store, et ce n'est pas de la ceinture
        # et des bretelles : sans lui nvim lit $XDG_CONFIG_HOME/nvim/init.lua
        # et charge tout $XDG_DATA_HOME/nvim/site/pack/*/start. Ces chemins-là
        # sont des liens symboliques qui T'APPARTIENNENT — donc remplaçables
        # par un fichier ordinaire, donc exécutables en root. Le runtime de
        # nvim reste chargé, la coloration YAML avec.
        #
        # CE QU'ON PERD : le thème stylix et le LSP pendant l'édition d'un
        # secret. Un YAML de treize kilo-octets s'édite très bien sans. C'est
        # le prix de la frontière posée par modules/system/sops, qui ne vaut
        # rien si cette commande-ci la reperce.
        editorBin="${pkgs-stable.neovim}/bin/nvim --clean"

        # Première ligne du bloc généré du .sops.yaml (lib/sops-policy.nix).
        marker=${lib.escapeShellArg myLib.sopsPolicy.marker}

        # anchors() : cf. scripts/lib/sops-anchors.sh, embarqué ici plutôt que
        # sourcé depuis le clone à l'exécution.
        ${myLib.sopsAnchorsSh}
      ''
      + builtins.readFile ./secrets.sh;
    })
  ];
}
