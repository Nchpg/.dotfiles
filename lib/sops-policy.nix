# Fabrique le bloc `creation_rules` du .sops.yaml du dépôt PRIVÉ à partir de ce
# que les configurations déclarent réellement.
#
# Pourquoi le générer plutôt que l'écrire : c'est la seule pièce du montage où
# une erreur ne se voit pas. Un secret rangé dans un fichier trop largement
# scellé continue de marcher — il marche même mieux, puisque plus de machines
# l'ouvrent. Rien n'échoue, rien n'avertit, et le rayon d'explosion grandit en
# silence. C'est exactement ce qui s'était produit : `system.yaml` scellé pour
# think ET gram, alors que gram n'avait besoin que de ses deux clés de tunnel.
#
# LE RAISONNEMENT, en trois temps :
#
#   1. Les cibles DÉPLOYÉES viennent de `systemSettings.sops.deployments` (cf.
#      hosts/default.nix). Pas les huit combinaisons du produit cartésien de
#      flake.nix : `server-gram` compile, mais personne ne l'active, et la
#      compter ici rendrait gram destinataire de tout — la faille d'origine.
#
#   2. L'AUDIENCE d'un secret est l'ensemble des MACHINES dont la cible
#      déployée le déclare, union faite sur ces cibles. Rien à annoter : un
#      secret déclaré par un module du profil server va aux machines qui font
#      tourner server ; un secret déclaré dans hosts/gram ne va qu'à gram. La
#      clé pré-partagée du tunnel, déclarée par le serveur ET par le client,
#      va aux deux sans qu'aucun des deux modules connaisse l'autre.
#
#      Par machine et non par profil, et ce n'est pas un détail : traduire
#      « déclaré sous personal » en « toutes les machines personal » donnait la
#      clé privée WireGuard de gram (déclarée par hosts/gram) à tout nouveau
#      portable personal, donc de quoi usurper gram sur le tunnel. Invisible
#      tant qu'il n'y avait qu'une machine par profil.
#
#   3. Les DESTINATAIRES suivent : machines -> leurs clés (système pour un
#      secret lu par un service, de compte pour un secret lu par une session).
#      C'est la traduction que sops ne peut pas faire seul, lui qui ne connaît
#      que des clés. `secretProfiles` élargit volontairement à un profil
#      entier.
#
# La sortie référence les ANCRES du .sops.yaml (`*think-sys`), jamais les clés
# elles-mêmes : la politique vit dans ce dépôt-ci, qui est public, le matériel
# de clé reste dans le privé. Les deux ne peuvent pas diverger sans que le check
# `sops-policy` de la CI le dise.
lib:

{
  # nixosConfigurations du flake, toutes cibles confondues.
  nixosConfigurations,
}:

let
  anyConfig = (builtins.head (lib.attrValues nixosConfigurations)).config;
  deployments = anyConfig.systemSettings.sops.deployments;

  # { host, profile } pour chaque couple réellement déployé.
  deployed = lib.concatLists (
    lib.mapAttrsToList (host: profiles: map (profile: { inherit host profile; }) profiles) deployments
  );

  configOf = t: nixosConfigurations."${t.profile}-${t.host}".config;

  # Accumule « nom du secret -> machines qui en ont besoin » sur les cibles
  # déployées : la machine de chaque cible qui le déclare, ou toutes celles des
  # profils qu'un `secretProfiles` désigne. `namesOf` dit où chercher les
  # déclarations, ce qui permet de faire tourner exactement le même calcul sur
  # les deux plans.
  audiencesBy =
    namesOf:
    lib.foldl' (
      acc: t:
      let
        c = configOf t;
        overrides = c.systemSettings.sops.secretProfiles;
      in
      lib.foldl' (
        a: name:
        a
        // {
          ${name} = lib.unique (
            (a.${name} or [ ]) ++ (if overrides ? ${name} then hostsFor overrides.${name} else [ t.host ])
          );
        }
      ) acc (namesOf c)
    ) { } deployed;

  # Les secrets lus par un SERVICE, scellés pour des clés de machines.
  sysAudiences = audiencesBy (c: lib.attrNames c.sops.secrets);

  # Ceux lus par une SESSION, scellés pour des clés de compte. Le calcul est
  # rigoureusement le même, et c'est le résultat qui compte : `git/email` est
  # déclaré par les deux profils, donc va aux deux comptes ; `gh/token`,
  # `vercel/token` et le reste ne sont déclarés que sous `personal`, donc ne
  # partent plus vers think. Cette machine-là est exposée sur internet et
  # détenait pourtant ton jeton GitHub pour n'avoir besoin que d'une adresse
  # de courriel — la même faille que côté système, en miroir.
  userAudiences = audiencesBy (
    c: lib.concatMap (u: lib.attrNames u.sops.secrets) (lib.attrValues c.home-manager.users)
  );

  # Un secret PEUT relever des deux plans à la fois, d'où l'union : le même
  # fichier reçoit alors des ancres `-sys` et des ancres `-user`.
  #
  # Aucun ne le fait aujourd'hui, et ce n'est pas un hasard. Le seul qui s'y
  # trouvait était `cloudflare/api_token` — lego en root sur think, wrangler
  # sous le compte de gram — et cette double nature n'était pas une propriété
  # du secret mais un défaut de portée : un seul jeton, porteur de
  # Zone:DNS:Edit, servait deux usages qui n'ont pas les mêmes besoins. Le
  # sceller pour une clé de COMPTE le mettait à portée de tout code lancé sous
  # cet utilisateur, sans passage par root. Deux jetons distincts, chacun sur
  # son plan, cf. modules/user/dev/cloudflare-cli.
  #
  # Le mécanisme reste, parce qu'un secret légitimement bi-plan peut réapparaître
  # — mais qu'un secret retombe dans ce cas mérite qu'on se demande d'abord si
  # ce sont vraiment les mêmes octets qu'il faut des deux côtés.
  allNames = lib.unique (lib.attrNames sysAudiences ++ lib.attrNames userAudiences);

  # Triées : l'ordre des ancres d'une règle ne doit dépendre que de qui la
  # reçoit, pas de l'ordre de parcours des cibles.
  anchorsFor =
    name:
    map (h: "${h}-sys") (lib.sort lib.lessThan (sysAudiences.${name} or [ ]))
    ++ map (h: "${h}-user") (lib.sort lib.lessThan (userAudiences.${name} or [ ]));

  hostsFor =
    profiles:
    lib.attrNames (lib.filterAttrs (_host: runs: lib.any (p: lib.elem p profiles) runs) deployments);

  # `.` est le seul métacaractère qui apparaisse dans un nom de secret.
  escape = lib.replaceStrings [ "." ] [ "\\." ];

  # MASQUAGE ENTRE RÈGLES, la seule erreur que ce fichier pouvait encore
  # produire en silence.
  #
  # sops retient la PREMIÈRE règle dont le motif correspond, et les motifs ne
  # sont pas ancrés à gauche (ils ne peuvent pas l'être, cf. `rule`). Le motif
  # d'un secret `a/b` correspond donc aussi au chemin d'un secret `p/a/b`, et
  # comme les règles sortent triées par nom, c'est parfois la plus COURTE qui
  # arrive devant : `token` précède `wireguard/token`, donc lui prendrait ses
  # destinataires.
  #
  # Le sens de la panne est celui qui ne se voit pas. Si l'audience du masquant
  # est plus étroite, le déchiffrement échoue et on le sait ; si elle est plus
  # large, tout fonctionne et le rayon d'explosion a grandi sans un mot. On
  # refuse donc d'émettre la politique plutôt que de trier par longueur, qui
  # règlerait le cas sans jamais dire que deux noms se marchent dessus.
  shadowing = lib.concatMap (
    a: map (b: "« ${a} » masque « ${b} »") (lib.filter (b: lib.hasSuffix "/${a}" b) allNames)
  ) allNames;

  # Rendu ligne à ligne plutôt qu'en chaînes multilignes : les `''…''` de Nix
  # rognent l'indentation commune, ce qui est très bien pour de la prose et
  # désastreux pour du YAML, dont l'indentation EST la syntaxe.
  #
  # ANCRÉ AUX DEUX BOUTS, `^…$`, et c'est le seul motif qui fonctionne : sops ne
  # confronte PAS le motif au chemin qu'on lui passe en ligne de commande, il le
  # rend d'abord relatif au répertoire du `.sops.yaml` (`filepath.Rel` dans
  # `parseCreationRuleForFile`). Le chemin testé pour un secret du dépôt est donc
  # toujours `wireguard/gram_preshared_key.yaml`, relatif à la racine du dépôt,
  # que la commande ait donné un chemin absolu ou non.
  #
  # La version précédente préfixait le motif d'une `/`, sur la prémisse inverse.
  # Aucune règle ne pouvait alors correspondre à un fichier DU dépôt : toute
  # création sortait en « no matching creation rules found », et le
  # rescellement (`sops updatekeys`) avec elle, sops chargeant la config avant de déchiffrer. Ça n'a pas sauté aux
  # yeux parce que les secrets existants sont antérieurs au découpage en un
  # fichier par secret, donc jamais recréés depuis.
  #
  # L'ancrage rend du même coup le masquage entre règles IMPOSSIBLE — `token` ne
  # peut plus attraper `wireguard/token.yaml`. Le contrôle `shadowing` ci-dessus
  # reste : il ne coûte rien, et c'est lui qui parlera si un jour l'ancrage
  # bouge.
  rule =
    path: anchors:
    [
      "  - path_regex: ^${escape path}\\.ya?ml$"
      "    key_groups:"
      "      - age:"
    ]
    ++ map (a: "          - *${a}") anchors;

  perSecret = lib.concatLists (
    map (name: rule name (anchorsFor name)) (lib.sort lib.lessThan allNames)
  );

  header = [
    "# ATTENTION : bloc GÉNÉRÉ. Ne pas l'éditer à la main — il est reconstruit"
    "# par `nix run .#sops-policy` depuis les configurations. Une édition"
    "# manuelle sera écrasée au prochain passage."
    "#"
    "# Une règle par secret, et AUCUNE règle large : un fichier qui ne"
    "# correspond à rien fait échouer sops au lieu d'être scellé par défaut."
    "creation_rules:"
  ];
in
lib.throwIf (shadowing != [ ])
  "lib/sops-policy : deux noms de secrets se masquent l'un l'autre (${lib.concatStringsSep ", " shadowing}). sops retient la première règle qui correspond, celle du nom le plus court peut donc prendre les destinataires de l'autre — et si elle est plus large, rien ne le signalera jamais. Renomme l'un des deux."
  (lib.concatStringsSep "\n" (header ++ perSecret) + "\n")
