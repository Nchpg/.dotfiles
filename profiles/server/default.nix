{ ... }:

let
  domain = import ./domain.nix;
in
{
  imports = [
    ./network.nix
    ./vpn.nix
    ./dns.nix
    ./authelia.nix
    ./monitoring.nix
    ./nextcloud.nix
    ./vaultwarden.nix
    ./apps.nix
    ./admin.nix
    ./pgweb.nix
  ];

  config = {
    systemSettings = {
      stylix.enable = true;

      sops.keyOwner = "nchpg";

      users = [
        {
          name = "nchpg";
          isAdmin = true;
          shell = "fish";
        }
      ];

      ssh = {
        enable = true;
        # Hors du 22 : vide le journal du bruteforce automatisé, pas une sécurité.
        port = 3249;
        # Clés autorisées : ajoutées ou retirées par le dashboard (page SSH), activées par `rebuild`.
        keysFile = ./ssh-keys.json;
        waypipe = true;
      };

      # `user` est l'identifiant technique Resend, distinct de l'adresse affichée.
      mail = {
        enable = true;
        host = "smtp.resend.com";
        user = "resend";
        domain = "nathanchampagne.com";
      };

      proxy = {
        enable = true;
        inherit domain;
        # Pas d'adresse : Let's Encrypt n'envoie plus d'avis d'expiration (juin 2025).
        acmeEmail = null;
      };

      notify.discord.enable = true;
    };

    # Sans --delete-older-than, les anciennes générations restent des racines du GC.
    nix.gc.options = "--delete-older-than 30d";
  };
}
