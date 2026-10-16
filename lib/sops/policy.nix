# Cibles DÉPLOYÉES (sops.deployments), pas le produit cartésien du flake : `server-gram` compile sans être activé.
lib:

let
  marker = "# ATTENTION : bloc GÉNÉRÉ";

  sopsAudience = import ./audience.nix lib;
  targetName = import ../flake/target-name.nix lib;
in
{
  inherit marker;

  generate =
    {
      nixosConfigurations,
    }:

    let
      anyConfig = (builtins.head (lib.attrValues nixosConfigurations)).config;
      deployments = anyConfig.systemSettings.sops.deployments;

      deployed = lib.concatLists (
        lib.mapAttrsToList (host: profiles: map (profile: { inherit host profile; }) profiles) deployments
      );

      configOf = t: nixosConfigurations.${targetName.machine t}.config;

      audiencesBy =
        namesOf:
        lib.foldl' (
          acc: t:
          let
            c = configOf t;
            audience = sopsAudience.audience {
              inherit deployments;
              inherit (c.systemSettings.sops) secretProfiles;
              inherit (t) host;
            };
          in
          lib.foldl' (
            a: name:
            a
            // {
              ${name} = lib.unique ((a.${name} or [ ]) ++ audience name);
            }
          ) acc (namesOf c)
        ) { } deployed;

      sysAudiences = audiencesBy (c: lib.attrNames c.sops.secrets);

      userAudiences = audiencesBy (
        c: lib.concatMap (u: lib.attrNames u.sops.secrets) (lib.attrValues c.home-manager.users)
      );

      allNames = lib.unique (lib.attrNames sysAudiences ++ lib.attrNames userAudiences);

      anchorsFor =
        name:
        map (h: "${h}-sys") (lib.sort lib.lessThan (sysAudiences.${name} or [ ]))
        ++ map (h: "${h}-user") (lib.sort lib.lessThan (userAudiences.${name} or [ ]));

      escape = lib.replaceStrings [ "." ] [ "\\." ];

      # sops retient la première règle qui correspond : `token` pourrait masquer `wireguard/token`.
      shadowing = lib.concatMap (
        a: map (b: "« ${a} » masque « ${b} »") (lib.filter (b: lib.hasSuffix "/${a}" b) allNames)
      ) allNames;

      # Lignes explicites : `''…''` rognerait l'indentation, qui est la syntaxe du YAML.
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
        "${marker}. Ne pas l'éditer à la main — il est reconstruit"
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
      (lib.concatStringsSep "\n" (header ++ perSecret) + "\n");
}
