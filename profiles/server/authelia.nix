{ ... }:

# Tunnel Cloudflare et portail d'authentification devant les noms publiés.
let
  domain = import ./domain.nix;
in
{
  systemSettings = {
    # Tunnel créé depuis gram (`cloudflared tunnel login` puis `tunnel create`,
    # qui exigent un navigateur). Ici ne tourne que le démon, nourri par le
    # JSON de credentials via sops.
    cloudflared = {
      enable = true;
      tunnelId = "4c8a6f06-b1cd-4a64-ba62-021113f68bda";
      # Les routes (`ingress`) découlent des noms publiés, cf.
      # `systemSettings.proxy.sites`.
    };

    # Équivalent auto-hébergé de Cloudflare Access, sans compte tiers ni carte
    # bancaire. Cf. le module pour la réserve sur l'absence d'audit.
    authelia = {
      enable = true;
      # Domaine RACINE, à contrecœur : le resserrer supposerait de loger le
      # portail sous cloud. (auth.cloud.…), or le certificat Universal SSL
      # gratuit de Cloudflare ne couvre qu'un niveau de joker et leur edge ne
      # présenterait alors aucun certificat valide.
      #
      # Conséquence assumée : le cookie de session part vers TOUS les
      # sous-domaines, site public compris. Il reste HttpOnly et Secure, donc
      # illisible par du JavaScript, mais le serveur qui héberge le site le
      # reçoit. À revoir si ce domaine héberge un jour quelque chose qui n'est
      # pas sous ton contrôle.
      inherit domain;
      portalHost = "auth.${domain}";

      # sops ne fait plus que semer : on déclare une personne avec un hachage
      # aléatoire que personne ne connaît, elle pose son mot de passe elle-même
      # par « mot de passe oublié ». Contrepartie : retirer quelqu'un de sops ne
      # le supprime plus du fichier vivant, la révocation demande d'y toucher à
      # la main.
      mutableUsers = true;
      # Sans ça, une authentification réussie depuis le portail lui-même
      # (notamment au retour d'un lien d'enrôlement, qui perd le `rd` de la
      # requête d'origine) laisse l'utilisateur bloqué sur la page du portail.
      defaultRedirect = "https://cloud.${domain}";

      # LES RÈGLES D'ACCÈS sont posées par les modules qui servent les noms
      # protégés : celles de Nextcloud par modules/system/server/nextcloud (en
      # tête, `mkBefore`), celle de Grafana dans monitoring.nix. La politique
      # par défaut est `deny` : un nom publié sans règle est fermé, pas ouvert.
    };
  };
}
