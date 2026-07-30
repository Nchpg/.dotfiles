{
  config,
  lib,
  inputs,
  ...
}:

{
  # Consommé par modules/user/sops (chemin du keyFile + outils pour ce user).
  options = {
    systemSettings.sops = {
      keyOwner = lib.mkOption {
        type = lib.types.str;
        example = "nchpg";
        description = ''
          Utilisateur qui détient la clé age (~/.config/sops/age/keys.txt,
          dérivée de sa clé SSH). Les autres users (dont root) réutilisent
          cette clé pour déchiffrer leurs secrets.
        '';
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = lib.any (
          user: user.name == config.systemSettings.sops.keyOwner
        ) config.systemSettings.users;
        message = "systemSettings.sops.keyOwner doit correspondre à un utilisateur déclaré dans systemSettings.users.";
      }
    ];

    # Pendant SYSTÈME de modules/user/sops (même fichier), pour les secrets que
    # consomme un service et non un utilisateur : une unité systemd ne lit pas
    # /run/user/<uid>/secrets, il lui faut /run/secrets, que seul ce module-ci
    # alimente.
    #
    # Inerte tant qu'aucun `sops.secrets` n'est déclaré : sops-nix n'ajoute son
    # script d'activation que s'il a quelque chose à déchiffrer.
    #
    # La clé de déchiffrement est celle de l'HÔTE quand la machine en a une,
    # c'est-à-dire /etc/ssh/ssh_host_ed25519_key, lisible par root seul. C'est
    # le défaut de sops-nix (`sops.age.sshKeyPaths`), qu'on se contente de ne
    # plus écraser.
    #
    # POURQUOI ça compte : ce fichier-ci déchiffre la clé privée WireGuard du
    # serveur, les credentials du tunnel Cloudflare, le jeton DNS, les secrets
    # de session d'Authelia et le mot de passe admin de Nextcloud. Tant que la
    # clé vivait dans le home du keyOwner, n'importe quel code tournant sous ce
    # compte les lisait tous, sans la moindre élévation — un agent, un prebuild
    # npm, n'importe quoi lancé par nix-ld. La barrière revient là où elle doit
    # être, au passage à root.
    #
    # UNE CLÉ AGE DÉDIÉE par machine, en 0600 sous root, la même mécanique
    # partout.
    #
    # `generateKey` est FAUX, et c'est délibéré : le script d'activation de
    # sops-nix appelle `age-keygen` sans `-pq`, donc il fabriquerait une clé
    # CLASSIQUE. Or les destinataires sont tous hybrides ML-KEM-768 + X25519, et
    # il n'y a pas de demi-mesure — `age` refuse de mélanger, mais sops accepte
    # le mélange sans un mot, et le fichier s'ouvrirait alors avec la seule clé
    # faible. Une machine qui s'auto-générerait une clé classique casserait donc
    # la propriété pour tout le monde.
    #
    # La clé est créée par `./init.sh`, qui passe `-pq`. Une machine sans clé
    # échoue à l'activation avec un message clair plutôt que de se fabriquer
    # discrètement une identité qui affaiblit l'ensemble.
    #
    # `sshKeyPaths` vidé, alors que c'est le défaut de sops-nix et que think a
    # bien une clé d'hôte SSH. Deux raisons de ne pas s'en servir :
    #
    #   - elle porte déjà l'identité SSH du serveur. Lui confier en plus le
    #     déchiffrement couple deux rôles sans rapport, si bien que régénérer la
    #     clé d'hôte après un doute sur la machine ferait cesser le
    #     déchiffrement, sans message.
    #   - sops n'accepte que des identités age, donc éditer un secret imposait de
    #     convertir la clé SSH à chaque fois. Une clé age native supprime la
    #     manœuvre, et la commande d'édition devient la même sur les deux hosts.
    #
    # Et ça règle le cas de gram, qui n'a pas de sshd donc aucune clé d'hôte : là
    # où sops-nix refusait de démarrer faute de source, il en fabrique une.
    #
    # La clé privée elle-même ne peut pas être déclarative : une valeur secrète
    # dans le store est lisible par tous les utilisateurs de la machine. Ce qui
    # se déclare, c'est sa génération. Corollaire à connaître : une machine qui
    # vient de la fabriquer n'est pas encore destinataire du fichier chiffré,
    # donc sa PREMIÈRE activation échoue au déchiffrement, après avoir créé la
    # clé. Il faut alors relever sa clé publique (`age-keygen -y`), l'ajouter
    # dans .sops.yaml, faire `sops updatekeys`, et relancer. Même cérémonie que
    # pour enrôler n'importe quelle machine dans sops.
    #
    # FICHIER SÉPARÉ de celui des secrets d'utilisateur, et c'est là que se joue
    # tout le durcissement. Le module lit `system.yaml`, chiffré pour les seules
    # clés système des machines ; `secrets.yaml` reste chiffré pour les clés
    # utilisateur et alimente modules/user/sops.
    #
    # Les deux viennent de l'entrée `secrets`, un dépôt PRIVÉ (cf. flake.nix) :
    # ce dépôt-ci est public, et y publier des valeurs emballées en X25519
    # revenait à les offrir à quiconque saura casser la courbe elliptique.
    #
    # Le déchiffrement par root ne protégeait de rien tant qu'un seul fichier
    # portait les deux : du code lancé sous ton compte n'a pas besoin de
    # /run/secrets, il ouvre le dépôt avec ta clé. Ce sont les DESTINATAIRES qui
    # décident, pas le processus qui déchiffre. Vérifié : `sops -d
    # secrets/system.yaml` sous nchpg est refusé.
    #
    # Le pendant utilisateur n'a pas besoin d'être protégé davantage : les outils
    # qui s'en servent (gh, wrangler, wakatime) tournent sous ton compte de toute
    # façon, donc l'y soustraire ne ferait que casser leur usage.
    #
    # `cloudflare/api_token` figure dans les DEUX fichiers, faute de mieux : ACME
    # le lit en root ici, wrangler le lit sous ton compte là-bas. À faire tourner
    # des deux côtés en même temps, sinon le renouvellement des certificats casse
    # en silence et ne se voit que quatre-vingt-dix jours plus tard.
    sops = {
      defaultSopsFile = "${inputs.secrets}/system.yaml";
      defaultSopsFormat = "yaml";

      age = {
        keyFile = "/var/lib/sops-nix/key.txt";
        generateKey = false;
        sshKeyPaths = [ ];
      };
    };
  };
}
