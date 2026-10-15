{
  config,
  lib,
  inputs,
  target,
  myLib,
  ...
}:

let
  cfg = config.systemSettings.sops;

  # UN SECRET = UN FICHIER, nommé d'après sa clé. Le nom n'est donc jamais à
  # choisir, et surtout il n'y a plus de « dans quel fichier je le range ? » —
  # la question qui, mal répondue une seule fois, élargit le rayon d'explosion
  # de toutes les valeurs qui partagent le fichier.
  #
  # AUCUN REPLI, et c'est le point d'arrivée de la migration : tant qu'un
  # fichier commun existait, un secret dont le nom ne correspondait à rien y
  # retombait en silence, donc restait scellé pour tout le parc sans que rien ne
  # le dise. sops-nix vérifie l'existence du chemin à l'ÉVALUATION : un nom qui
  # ne correspond à rien fait désormais échouer le rebuild, ce qui est le seul
  # comportement acceptable pour une valeur dont l'audience est en jeu.
  secretFile = name: "${inputs.secrets}/${name}.yaml";

  declared = lib.attrNames config.sops.secrets;

  # Machines qui ont besoin de ce secret, vues d'ici. Le défaut — CETTE machine,
  # qui est en train de le déclarer — est presque toujours le bon, et c'est ce
  # qui rend le mécanisme automatique, sans qu'on l'écrive nulle part.
  #
  # Le générateur de politique évalue TOUTES les cibles déployées et fait
  # l'UNION (cf. lib/sops/policy.nix). Un secret déclaré des deux côtés d'un
  # tunnel — la clé pré-partagée, par le serveur et par le client — va donc aux
  # deux, sans qu'aucun des deux modules connaisse l'autre. Même calcul des
  # deux côtés, cf. lib/sops/audience.nix.
  audience = myLib.sops.audience.audience {
    inherit (cfg) deployments secretProfiles;
    inherit (target) host;
  };

  # Cette cible est-elle une machine réelle, ou une des combinaisons que le
  # produit cartésien de flake.nix fabrique et que personne n'active ?
  deployedHere = lib.elem target.profile (cfg.deployments.${target.host} or [ ]);

  # Secrets que cette machine déclare sans figurer parmi les destinataires du
  # fichier correspondant. Vide par construction quand on s'en tient au défaut
  # ci-dessus — l'audience étant « qui le déclare », on ne peut pas se retrouver
  # hors de sa propre audience. Ça cesse d'être vrai dès qu'un `secretProfiles`
  # est écrit à la main, ou que `deployments` oublie la machine.
  unreadable = lib.filter (name: !(lib.elem target.host (audience name))) declared;

in
{
  # Consommé par modules/user/sops (chemin du keyFile + outils pour ce user).
  options = {
    systemSettings.sops = {
      keyOwner = lib.mkOption {
        type = lib.types.str;
        example = "nchpg";
        description = ''
          Utilisateur qui détient la clé age (~/.config/sops/age/keys.txt,
          identité dédiée générée par ./init.sh). Les autres users (dont root)
          réutilisent cette clé pour déchiffrer leurs secrets.
        '';
      };

      deployments = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = { };
        example = {
          think = [ "server" ];
          gram = [ "personal" ];
        };
        description = ''
          Quelle machine fait tourner quels profils, POUR DE VRAI.

          C'est la seule information de tout ce montage qui ne se dérive de
          rien, et il faut comprendre pourquoi avant de vouloir s'en passer :
          `flake.nix` construit ses cibles par produit cartésien, donc
          `server-gram` et `personal-think` existent et compilent au même titre
          que les autres. Du seul point de vue du dépôt, « les machines qui font
          tourner server » veut donc dire « toutes », et c'est exactement ce qui
          donnait à gram de quoi ouvrir les secrets du serveur.

          Cette table N'AJOUTE PAS une obligation, elle en déplace une : le
          `.sops.yaml` du dépôt privé dit déjà la même chose, en ancres de clés
          age de 1800 caractères, dans un autre dépôt, sans lien avec les
          modules et sans que rien ne vérifie qu'elle est à jour.

          Ce qu'elle NE FAIT PAS : interdire de construire une combinaison. On
          peut rebuild `personal-think` sans rien changer ici — cette cible ne
          déclare aucun secret système, il n'y a rien à déchiffrer. Ce qui
          échouerait, c'est d'ACTIVER une cible qui déclare des secrets dont la
          machine n'est pas destinataire, `server-gram` typiquement. Pour le
          permettre, il faut le vouloir : `gram = [ "personal" "server" ]`, puis
          resceller. C'est le moment où l'on confie les clés de la maison au
          portable, ça se déclare.
        '';
      };

      secretProfiles = lib.mkOption {
        type = lib.types.attrsOf (lib.types.listOf lib.types.str);
        default = { };
        example = {
          "wireguard/gram_preshared_key" = [
            "server"
            "personal"
          ];
        };
        description = ''
          Élargissement DÉLIBÉRÉ de l'audience d'un secret, par nom.

          À ne renseigner que dans un cas : un rôle a besoin d'ouvrir un secret
          qu'il ne déclare pas lui-même. Sinon, ne rien écrire — l'audience par
          défaut d'un secret est la machine qui le déclare, et le générateur
          fait l'union sur toutes les cibles déployées, ce qui couvre déjà le
          cas des valeurs partagées entre deux machines qui les déclarent
          toutes les deux. Renseigné, il donne le secret à TOUTES les machines
          de ces profils.

          Élargir à une MACHINE ne se fait pas ici mais dans `deployments` : ici
          on parle de rôles, la traduction en clés de machines vient de là-bas.
        '';
      };
    };

    # Extension du sous-module de sops-nix : on ne lui AJOUTE aucune option, on
    # se contente de poser un défaut sur le sien.
    #
    # Deux raisons de ne pas passer par une option parallèle à nous, toutes deux
    # apprises en le faisant :
    #
    #   - son `restartUnits` est un `listOf str`, qui FUSIONNE quand deux
    #     modules déclarent le même secret. C'est le cas de la clé pré-partagée
    #     du tunnel, déclarée par le serveur et par le client. Une option maison
    #     en `attrsOf anything` casse cette fusion — `anything` ne sait pas
    #     fusionner deux listes et échoue sur « conflicting definition values ».
    #   - `manifest-for.nix` sérialise `builtins.attrValues secrets` EN ENTIER
    #     dans le JSON qu'il passe à sops-install-secrets. Toute option qu'on
    #     ajouterait au sous-module s'y retrouverait.
    #
    # En ne posant qu'un défaut sur `sopsFile`, les modules continuent d'écrire
    # `sops.secrets.<clé> = { … }` comme avant : rien à migrer, rien à retenir,
    # et le fichier chiffré est déduit du nom sans que personne ait à le choisir.
    sops.secrets = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            config.sopsFile = lib.mkDefault (secretFile name);
          }
        )
      );
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
      {
        # Un secret déclaré par une machine qui n'est destinataire d'aucun
        # fichier le contenant échouerait à l'ACTIVATION, sur un message de
        # sops-nix qui parle de déchiffrement et pas de politique. On le dit ici.
        #
        # Uniquement sur une cible RÉELLE : `nix flake check` construit les huit
        # combinaisons, et `server-gram` doit continuer de compiler. Elle produit
        # un avertissement à la place, cf. `warnings`.
        assertion = !deployedHere || unreadable == [ ];
        message = "systemSettings.sops : ${target.host} déclare des secrets dont elle n'est destinataire d'aucun fichier (${lib.concatStringsSep ", " unreadable}). Ajoute son profil dans systemSettings.sops.deployments, ou élargis `profiles` sur ces secrets, puis `secrets policy`.";
      }
    ];

    warnings =
      lib.optional (cfg.deployments != { } && !(cfg.deployments ? ${target.host}))
        "systemSettings.sops.deployments ne mentionne pas ${target.host} : aucun secret ne sera scellé pour cette machine. C'est normal pour une cible qu'on ne fait que construire."
      ++
        lib.optional (!deployedHere && unreadable != [ ])
          "systemSettings.sops : ${target.machine} n'est pas une cible déployée et déclare des secrets qu'elle ne pourrait pas déchiffrer (${lib.concatStringsSep ", " unreadable}). Sans conséquence tant qu'on ne fait que la construire.";

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
    # UN FICHIER PAR SECRET, et plus de fichier commun du tout. C'est là que se
    # joue tout le durcissement, et l'histoire vaut d'être connue parce qu'elle
    # explique la forme du mécanisme.
    #
    # Il y a d'abord eu UN fichier, portant les secrets système et les tiens :
    # le déchiffrement par root ne protégeait alors de rien, puisque du code
    # lancé sous ton compte n'a pas besoin de /run/secrets — il ouvre le dépôt
    # avec ta clé. Ce sont les DESTINATAIRES qui décident, pas le processus qui
    # déchiffre.
    #
    # Puis DEUX, système et utilisateur. Mieux, mais la frontière entre
    # MACHINES manquait toujours : `system.yaml` était scellé pour think ET
    # gram, si bien que le portable ouvrait la clé privée WireGuard du serveur,
    # les credentials du tunnel Cloudflare et les secrets de session d'Authelia
    # — pour n'avoir besoin que de ses deux clés de tunnel.
    #
    # Aujourd'hui, un fichier par secret : les destinataires se calculent depuis
    # ce que les configurations déclarent (cf. `deployments` plus haut et
    # lib/sops/policy.nix), donc le rayon d'explosion d'une valeur ne dépend plus
    # du fichier où quelqu'un l'a rangée un jour.
    #
    # Pas de `defaultSopsFile` : il n'y a plus de défaut qui aurait un sens, et
    # son absence est une protection. Un secret dont personne n'a posé le
    # `sopsFile` échoue à l'évaluation au lieu d'atterrir dans un fourre-tout —
    # or c'est exactement comme ça qu'une valeur finit scellée trop largement,
    # sans que rien ne le signale. Le sous-module plus haut le pose pour tous.
    #
    # Les fichiers viennent de l'entrée `secrets`, un dépôt PRIVÉ (cf.
    # flake.nix) : ce dépôt-ci est public, et y publier des valeurs emballées en
    # X25519 revenait à les offrir à quiconque saura casser la courbe elliptique.
    sops = {
      defaultSopsFormat = "yaml";

      age = {
        keyFile = "/var/lib/sops-nix/key.txt";
        generateKey = false;
        sshKeyPaths = [ ];
      };
    };
  };
}
