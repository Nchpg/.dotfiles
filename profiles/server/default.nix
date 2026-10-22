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
          sshKeys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILtpLQKGuQttRPNQTdMOjLpx1kn5oM94wj97klIh5Upf nchpg@gram"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDFLQKGgSPS//aBeJ0ZnXvDV9sr7XYC7Qu/NUIHy9B+9 nchpg@xiaomi-17t-termux"
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC1ZsoIRAXJRR0crPgfWJRPCNBQ+pdWqkMX6qmCq+4y1 nchpg@windows"
          ];
        }
      ];

      ssh = {
        enable = true;
        # Hors du 22 : vide le journal du bruteforce automatisé, pas une sécurité.
        port = 3249;
      };

      # `user` est l'identifiant technique Resend, distinct de l'adresse affichée.
      mail = {
        enable = true;
        host = "smtp.resend.com";
        user = "resend";
        from = "nextcloud@nathanchampagne.com";
      };

      proxy = {
        enable = true;
        inherit domain;
        # Pas d'adresse : Let's Encrypt n'envoie plus d'avis d'expiration (juin 2025).
        acmeEmail = null;
      };

      notify.discord.enable = true;

      # Précondition : compte région EUROPE, puis `secrets edit datadog/api_key` et commit du lock,
      # sinon l'évaluation échoue.
      datadog.enable = true;
    };

    # Sans --delete-older-than, les anciennes générations restent des racines du GC.
    nix.gc.options = "--delete-older-than 30d";
  };
}
