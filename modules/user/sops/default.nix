{
  config,
  lib,
  osConfig,
  inputs,
  ...
}:

# Config globale sops-nix ; secrets/templates individuels déclarés dans les
# modules qui les consomment (tui/calendar, tui/task).
# Clé de déchiffrement : ~/.config/sops/age/keys.txt, identité age DÉDIÉE
# générée par `./init.sh` (hybride ML-KEM-768 + X25519, cf. son en-tête). Elle
# n'est plus dérivée de la clé SSH : une ed25519 ne donne que du X25519.
# Éditer un secret : `secrets edit <nom>`. Cf. docs/secrets.md.
let
  keyOwner = osConfig.systemSettings.sops.keyOwner;

  # Peut lire la clé age : le keyOwner ou root (outrepasse les permissions).
  #
  # RÉSERVE CONNUE, à garder en tête avant d'ajouter quoi que ce soit ici : le
  # keyFile plus bas vit dans le home du keyOwner, donc dans un répertoire que
  # cet utilisateur POSSÈDE. root va y chercher une clé à chaque activation, et
  # un processus non privilégié peut remplacer ce fichier par un lien ou par
  # autre chose. La dépendance va dans le mauvais sens.
  #
  # Pourquoi c'est toléré : le seul secret que root tire d'ici est `git/email`
  # (défaut de modules/user/git pour un user qui a accès), une adresse que le keyOwner détient déjà
  # puisque c'est SA clé. Substituer le fichier ne révèle donc rien de neuf, le
  # pire effet est de faire échouer l'activation de root — une gêne, pas une
  # élévation.
  #
  # CE QUI CHANGERAIT LA DONNE : un secret réellement sensible déclaré sous
  # root. Il ne doit pas passer par ce module, mais par sops.secrets au niveau
  # SYSTÈME (modules/system/sops), qui déchiffre avec la clé de la machine en
  # 0600 root.
  hasSopsAccess = config.userSettings.user == keyOwner || config.userSettings.user == "root";
in
{
  options.userSettings.sops.available = lib.mkOption {
    type = lib.types.bool;
    readOnly = true;
    description = ''
      Vrai si ce user a accès aux secrets sops (keyOwner ou root). Les modules
      qui déclarent des secrets (tui/calendar, tui/task, git/gh, editors/wakatime,
      git-email) peuvent asserter dessus pour échouer avec un message clair au
      lieu d'une erreur sops-nix cryptique quand ils sont activés pour un user
      sans clé. NB : ne vérifie QUE le droit d'accès (eval pur) — que la clé
      soit bien présente et déchiffre est vérifié par sops-nix à l'activation.

      Vrai pour root ne veut pas dire « root peut tout se permettre ici » : cf.
      la réserve sur hasSopsAccess plus haut avant de lui déclarer un secret qui
      compte.
    '';
  };

  # Même mécanique que côté système : on n'AJOUTE aucune option au sous-module
  # de sops-nix, on pose seulement un défaut sur le sien. Ajouter une option la
  # ferait fuiter dans le manifeste JSON, qui sérialise le sous-module en
  # entier, et casserait la fusion de listes de `restartUnits`.
  #
  # Hors du `mkIf hasSopsAccess` plus bas, parce qu'une DÉCLARATION d'option
  # n'est pas une définition : elle ne force rien pour les users sans clé.
  options.sops.secrets = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          config.sopsFile = lib.mkDefault "${inputs.secrets}/${name}.yaml";
        }
      )
    );
  };

  config = {
    userSettings.sops.available = hasSopsAccess;

    # Seulement pour le détenteur de la clé.
    home.packages = lib.mkIf (config.userSettings.user == keyOwner) (
      with config.userSettings.defaultPkgs;
      [
        sops
        age
        ssh-to-age
      ]
    );

    # UN SECRET = UN FICHIER, exactement comme côté système (cf.
    # modules/system/sops, qui porte le raisonnement complet). Le fichier se
    # déduit du nom du secret, personne n'a donc à le choisir.
    #
    # Ce que ça change ICI, et ce n'était pas cosmétique : `secrets.yaml` était
    # scellé pour les comptes de TOUTES les machines. Think n'a besoin que de
    # `git/email` et détenait pourtant le jeton GitHub, ceux de Vercel et
    # Supabase, les secrets OAuth Google et la clé WakaTime — la même faille que
    # côté système, en miroir, sauf que c'est la machine exposée sur internet
    # qui portait le surplus.
    #
    # Les destinataires se déduisent des profils qui DÉCLARENT le secret :
    # `git/email` est déclaré par server et par personal, donc part aux deux
    # comptes ; `gh/token` n'est déclaré que sous personal, donc ne quitte plus
    # gram. Rien à annoter, cf. lib/sops-policy.nix.
    #
    # Et `cloudflare/api_token` ne va plus qu'à `think-sys`. Il a d'abord existé
    # en DOUBLE, un fichier par plan, avec la panne que ça implique — tourner
    # l'une des deux copies sans l'autre, et le renouvellement des certificats
    # casse en silence pendant quatre-vingt-dix jours. La réponse a été de n'en
    # faire qu'un, scellé pour les deux, ce qui réglait la synchronisation en
    # payant le PRIVILÈGE : ce jeton porte Zone:DNS:Edit pour la validation
    # DNS-01, et le sceller aussi pour une clé de compte le mettait à portée de
    # tout code lancé sous cet utilisateur, sans passage par root.
    #
    # La bonne réponse était qu'il n'y ait pas une valeur mais DEUX, taillées
    # chacune sur son usage : `cloudflare/api_token` pour ACME, en root sur
    # think, et `cloudflare/wrangler_token` (Workers/Pages) le jour où wrangler
    # revient. Deux valeurs différentes n'ont rien à tenir aligné, la panne de
    # synchronisation n'a donc pas de support non plus.
    sops = lib.mkIf hasSopsAccess {
      defaultSopsFormat = "yaml";

      age = {
        # root réutilise la clé du keyOwner : il peut déjà tout déchiffrer
        # sur la machine, aucune perte de sécurité, pas de clé à part. Sur ce
        # que ça implique quand même, cf. la réserve sur hasSopsAccess.
        keyFile = "/home/${keyOwner}/.config/sops/age/keys.txt";
        generateKey = false;
      };
    };
  };
}
