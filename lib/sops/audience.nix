# Audience d'un secret : les MACHINES qui doivent pouvoir l'ouvrir. Partagé
# par modules/system/sops (vue d'une cible : suis-je destinataire de ce que je
# déclare ?) et lib/sops/policy.nix (union sur toutes les cibles déployées),
# qui doivent faire exactement le même calcul.
lib: rec {
  # Machines qui font tourner au moins un des profils donnés. C'est LA
  # traduction que rien d'autre ne peut faire : les modules raisonnent en
  # rôles, sops ne connaît que des clés de machines.
  hostsFor =
    deployments: profiles:
    lib.attrNames (lib.filterAttrs (_host: runs: lib.any (p: lib.elem p profiles) runs) deployments);

  # Machines qui ont besoin du secret `name` déclaré par `host` : par défaut
  # cette machine-là, ou toutes celles des profils qu'un `secretProfiles`
  # désigne (élargissement délibéré).
  audience =
    {
      deployments,
      secretProfiles,
      host,
    }:
    name: if secretProfiles ? ${name} then hostsFor deployments secretProfiles.${name} else [ host ];
}
