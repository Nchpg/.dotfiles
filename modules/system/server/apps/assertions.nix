{
  config,
  lib,
  ...
}:

let
  cfg = config.systemSettings.apps;

  authelia = config.systemSettings.authelia;

  images = config.systemSettings.appImages.helpers;

  hostPorts = map (a: a.hostPortEffective) (lib.attrValues cfg);

  otherPorts =
    lib.optional config.systemSettings.authelia.enable config.systemSettings.authelia.port
    ++ lib.optional config.services.vaultwarden.enable config.services.vaultwarden.config.ROCKET_PORT;
in
{
  config = lib.mkIf (cfg != { }) {
    warnings = lib.mapAttrsToList (
      name: _:
      "systemSettings.apps.${name}.public est obsolète : `expose = \"public\"`, `\"vpn\"` ou `\"sso\"`."
    ) (lib.filterAttrs (_: a: a.public != null) cfg);

    assertions = [
      {
        assertion = config.systemSettings.proxy.enable;
        message = "systemSettings.apps exige systemSettings.proxy.enable : c'est lui qui porte nginx et l'obtention des certificats.";
      }
      {
        assertion =
          lib.all (a: a.expose == "vpn") (lib.attrValues cfg) || config.systemSettings.cloudflared.enable;
        message = "systemSettings.apps : une application `expose = \"public\"` ou `\"sso\"` a besoin de systemSettings.cloudflared.enable pour être routée, aucun port n'étant ouvert sur la box.";
      }
      {
        assertion = lib.all (a: a.expose == "vpn" || a.allowedNetworks == null) (lib.attrValues cfg);
        message = "systemSettings.apps : `allowedNetworks` n'a de sens qu'avec `expose = \"vpn\"` — tout ce qui vient du tunnel Cloudflare se présente en 127.0.0.1.";
      }
      {
        # `public` (obsolète) ou `allowedNetworks` explicite : déclarations antérieures, filtrées autrement.
        assertion = lib.all (
          a: a.expose != "vpn" || a.devices != null || a.allowedNetworks != null || a.public != null
        ) (lib.attrValues cfg);
        message = "systemSettings.apps : une application `expose = \"vpn\"` doit lister ses `devices` (noms de vpn.wireguard.peers) : ${
          toString (
            lib.attrNames (
              lib.filterAttrs (
                _: a: a.expose == "vpn" && a.devices == null && a.allowedNetworks == null && a.public == null
              ) cfg
            )
          )
        }.";
      }
      {
        # `vpn.<domaine>` est le point d'entrée WireGuard (enregistrement « DNS only » vers la box).
        assertion = lib.all (a: !(a.expose == "vpn" && a.subdomain == "@")) (lib.attrValues cfg);
        message = "systemSettings.apps : `subdomain = \"@\"` est impossible en `expose = \"vpn\"`, ce nom est celui du tunnel WireGuard.";
      }
      {
        assertion = lib.all (a: a.devices == null || a.expose == "vpn") (lib.attrValues cfg);
        message = "systemSettings.apps : `devices` ne s'applique qu'avec `expose = \"vpn\"`.";
      }
      {
        assertion = lib.all (a: a.expose != "sso") (lib.attrValues cfg) || authelia.enable;
        message = "systemSettings.apps : `expose = \"sso\"` exige systemSettings.authelia.enable, c'est lui qui tient le portail.";
      }
      {
        # Sinon le cookie de session n'est jamais envoyé : boucle de redirection vers le portail.
        assertion = lib.all (
          a: a.expose != "sso" || authelia.domain == null || lib.hasSuffix ".${authelia.domain}" a.domain
        ) (lib.attrValues cfg);
        message = "systemSettings.apps : une application `expose = \"sso\"` doit être servie sous systemSettings.authelia.domain (${toString authelia.domain}), sinon le cookie du portail ne la couvre pas.";
      }
      {
        assertion = lib.all (a: a.allowedNetworks != [ ]) (lib.attrValues cfg);
        message = "systemSettings.apps : `allowedNetworks` est vide, donc nginx refuserait toute source. `null` pour ne pas filtrer.";
      }
      {
        assertion = lib.all (a: a.containers != { }) (lib.attrValues cfg);
        message = "systemSettings.apps : une application sans conteneur ne sert rien, et son vhost renverrait une erreur de passerelle.";
      }
      {
        assertion = lib.all (a: a.entrypoint != null || lib.length (lib.attrNames a.containers) == 1) (
          lib.attrValues cfg
        );
        message = "systemSettings.apps : `entrypoint` est requis dès qu'une application a plusieurs conteneurs — c'est celui que nginx sert.";
      }
      {
        assertion = lib.all (a: a.entrypoint == null || a.containers ? ${a.entrypoint}) (
          lib.attrValues cfg
        );
        message = "systemSettings.apps : `entrypoint` doit nommer un conteneur déclaré dans `containers`.";
      }
      {
        assertion = lib.all (
          a:
          let
            c = a.containers.${a.entrypointName};
          in
          c.port != null || images.port c.image != null
        ) (lib.attrValues cfg);
        message = "systemSettings.apps : le conteneur servi par nginx n'a pas de port : son image ne déclare aucun `EXPOSE` unique dans le lock, donne-lui un `port`.";
      }
      {
        assertion = lib.all (a: lib.all (p: lib.hasPrefix "/" p) a.rateLimit.paths) (lib.attrValues cfg);
        message = "systemSettings.apps : les `rateLimit.paths` sont des chemins nginx, ils commencent par « / ».";
      }
      {
        assertion = lib.all (
          a: lib.all (c: lib.all (d: a.containers ? ${d}) c.dependsOn) (lib.attrValues a.containers)
        ) (lib.attrValues cfg);
        message = "systemSettings.apps : un `dependsOn` doit nommer un conteneur de la MÊME application.";
      }
      {
        assertion = lib.all (
          a: lib.all (n: !(lib.elem n a.containers.${n}.dependsOn)) (lib.attrNames a.containers)
        ) (lib.attrValues cfg);
        message = "systemSettings.apps : un conteneur ne peut pas dépendre de lui-même.";
      }
      {
        assertion = lib.all (n: builtins.match "[a-zA-Z0-9][a-zA-Z0-9_-]*" n != null) (
          lib.attrNames cfg ++ lib.concatMap (a: lib.attrNames a.containers) (lib.attrValues cfg)
        );
        message = "systemSettings.apps : les noms d'applications et de conteneurs se limitent à des lettres, chiffres, tirets et soulignés, et commencent par un caractère alphanumérique.";
      }
      {
        # IFNAMSIZ : au-delà, podman échoue sans désigner le nom.
        assertion = lib.all (a: lib.stringLength a.bridge <= 15) (lib.attrValues cfg);
        message = "systemSettings.apps : le nom d'une application doit tenir en 12 caractères — le pont réseau s'appelle `br-<nom>` et le noyau limite un nom d'interface à 15. Le nom SERVI n'est pas concerné, c'est `domain` et il reste libre.";
      }
      {
        assertion = lib.all (
          a: lib.all (c: lib.all (v: lib.hasPrefix "/" v.target) c.volumes) (lib.attrValues a.containers)
        ) (lib.attrValues cfg);
        message = "systemSettings.apps : la `target` d'un montage est un chemin absolu dans le conteneur.";
      }
      {
        assertion = lib.all (
          a:
          lib.all (
            c:
            lib.all (
              v:
              !(lib.elem v.source [
                "/"
                "/etc"
                "/boot"
                "/nix"
                "/run"
              ])
              && !(lib.any (p: v.source == p || lib.hasPrefix "${p}/" v.source) [
                "/dev"
                "/proc"
                "/sys"
                "/var/lib/containers"
              ])
            ) c.volumes
          ) (lib.attrValues a.containers)
        ) (lib.attrValues cfg);
        message = "systemSettings.apps : ce montage donne au conteneur un répertoire système du host — racine, /nix, /etc, /run, /boot, /dev, /proc, /sys ou l'espace de stockage des conteneurs. Aucune application web n'en a besoin, et un accès en écriture à l'un d'eux vaut une évasion complète.";
      }
      {
        # `extraInputRules` est ignoré en silence par le backend iptables.
        assertion = config.networking.nftables.enable;
        message = "systemSettings.apps exige networking.nftables.enable, seul backend où les règles du module (DNS des conteneurs, trafic interne à chaque application) sont appliquées.";
      }
      {
        assertion = lib.length (lib.unique hostPorts) == lib.length hostPorts;
        message = "systemSettings.apps : deux applications tombent sur le même port de bouclage (${
          lib.concatStringsSep ", " (lib.mapAttrsToList (n: a: "${n}=${toString a.hostPortEffective}") cfg)
        }). Fixe le `hostPort` de l'une d'elles.";
      }
      {
        assertion = lib.intersectLists hostPorts otherPorts == [ ];
        message = "systemSettings.apps : un port de bouclage (${lib.concatStringsSep ", " (map toString (lib.intersectLists hostPorts otherPorts))}) est déjà pris par un autre service du host (Authelia, Vaultwarden). Choisis un autre `hostPort`.";
      }
    ];
  };
}
