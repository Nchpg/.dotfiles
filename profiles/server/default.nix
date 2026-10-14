{ ... }:

# Profil headless : ni session graphique ni GDM (cf. modules/system/desktop, dont
# le défaut suit la présence d'un window manager), une IP fixe et SSH. Prévu
# pour tourner sur le host think, cible `server-think`.
#
# Découpé par sujet, un fichier par service ou presque ; celui-ci ne garde que
# le socle de la machine. `domain.nix` porte le domaine que tous reprennent.
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
  ];

  config = {
    systemSettings = {
      # Thémise les TTY, seul rendu local d'un host sans session graphique :
      # sinon la console garde la palette Linux par défaut et la même commande
      # n'a pas les mêmes couleurs sur l'écran de la machine et en SSH depuis
      # gram. Les targets GUI suivent systemSettings.desktop.enable, faux ici.
      stylix.enable = true;

      # nchpg détient la clé age qui déchiffre le dépôt de secrets.
      sops.keyOwner = "nchpg";

      users = [
        {
          name = "nchpg";
          isAdmin = true;
          # Login TTY/SSH en fish, aligné sur userSettings.shell.default.
          shell = "fish";
          # Le commentaire en fin de ligne n'a AUCUN rôle cryptographique : c'est
          # du texte libre, et c'est le seul moyen de savoir à quoi correspond
          # une clé le jour où il faut en révoquer une. On le réécrit donc pour
          # nommer l'appareil, au lieu de garder ce que l'outil a généré —
          # `u0_a375@localhost` pour la seconde, un identifiant d'application
          # Android qui ne dit rien à personne.
          sshKeys = [
            # gram, le poste depuis lequel on administre la machine.
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILtpLQKGuQttRPNQTdMOjLpx1kn5oM94wj97klIh5Upf nchpg@gram"
            # Termux sur le téléphone, pour dépanner sans ordinateur — le cas où
            # l'on est dehors, en VPN, et où il faut relancer quelque chose.
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDFLQKGgSPS//aBeJ0ZnXvDV9sr7XYC7Qu/NUIHy9B+9 nchpg@xiaomi-17t-termux"
            # Le poste sous Windows, d'où l'on se connecte quand on n'est pas sur
            # gram.
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC1ZsoIRAXJRR0crPgfWJRPCNBQ+pdWqkMX6qmCq+4y1 nchpg@windows"
          ];
        }
      ];

      ssh = {
        enable = true;
        # Hors du port 22 : aucune sécurité en soi (un scan trouve le port en
        # quelques secondes), mais ça vide le journal des tentatives de
        # bruteforce automatisées qui ne tapent que sur 22.
        port = 3249;
      };

      # Relais SMTP partagé par Authelia et Nextcloud, déclaré une seule fois :
      # changer d'hébergeur se limite à ces lignes et au secret sops.
      #
      # Relais transactionnel plutôt qu'une boîte sur le domaine : chez IONOS les
      # boîtes supplémentaires sont facturées, et l'alias Gmail aurait fait
      # apparaître « via gmail.com » chez les destinataires sous Outlook. `user`
      # est un identifiant technique imposé par Resend, distinct de l'adresse
      # affichée — c'est le cas que le module sépare.
      #
      # Vérifié en conditions réelles : DKIM signe avec d=nathanchampagne.com,
      # l'alignement DMARC est donc strict et le Return-Path reste sur
      # send.nathanchampagne.com.
      mail = {
        enable = true;
        host = "smtp.resend.com";
        user = "resend";
        from = "nextcloud@nathanchampagne.com";
      };

      # nginx + ACME, socle des vhosts du host.
      proxy = {
        enable = true;
        # Aucune adresse : les avis d'expiration de Let's Encrypt ont cessé le
        # 4 juin 2025, donc le champ ne recevait plus rien. Ce qui surveille le
        # renouvellement est `notify.discord` ci-dessous, qui prévient à
        # l'échec plutôt qu'à l'expiration.
        #
        # Ce qu'on abandonne : le canal par lequel Let's Encrypt préviendrait
        # d'une révocation de masse. Assumé — ça arrive une fois par décennie et
        # ça se sait par ailleurs, alors qu'une adresse personnelle dans un dépôt
        # public se fait moissonner en continu.
        acmeEmail = null;
      };

      # Prévient quand une unité échoue, sur une machine que personne ne regarde.
      # Le webhook est un identifiant : il vit dans les secrets système, pas ici.
      notify.discord.enable = true;

      # Agent Datadog : les mêmes mesures que ci-dessus, mais DÉPOSÉES AILLEURS.
      # C'est tout ce qu'il apporte, et c'est assumé — Prometheus voit plus de
      # choses et garde quatre-vingt-dix jours quand le gratuit de Datadog en
      # garde un. Ce qu'on gagne : pouvoir regarder les dernières vingt-quatre
      # heures de courbes de think depuis un navigateur au moment où think ne
      # répond plus, donc où Grafana est injoignable avec elle.
      #
      # AUCUN LOG N'EST ENVOYÉ, et ce n'est pas un réglage oublié : Log
      # Management est un produit payant chez Datadog, jamais compris dans le
      # gratuit. L'essai de quatorze jours d'un compte neuf le fait fonctionner
      # le temps qu'on s'y habitue, puis il s'arrête sans message. Le module
      # coupe donc la collecte explicitement ; son en-tête donne les trois lignes
      # à écrire et l'ordre de grandeur de la facture (~1 $/mois ici) le jour où
      # l'on voudrait vraiment lire le journal depuis leur interface.
      #
      # PRÉCONDITION HORS DÉPÔT, dans cet ordre, sans quoi le rebuild échoue à
      # l'ÉVALUATION sur « Cannot find path … datadog/api_key.yaml » :
      #
      #   1. créer le compte sur la région EUROPE (le site ne se change plus
      #      après coup, cf. l'option `site` du module) et relever la clé d'API ;
      #   2. `secrets edit datadog/api_key` pour poser la valeur : la règle de
      #      création, qui découle de cette déclaration-ci, est posée d'abord
      #      dans le .sops.yaml, puis le dépôt privé et le lock sont synchronisés ;
      #   3. commit du lock, rebuild.
      datadog = {
        enable = true;

        # Aucune étiquette : filtrer un parc d'une seule machine ne sert à rien.
        # À renseigner le jour où une deuxième émet vers le même compte — c'est
        # le seul moyen de les distinguer autrement qu'une par une.
      };

      # Cf. le module : l'écrasante majorité des compromissions à distance
      # exploitent une faille déjà corrigée. L'URL est distante à dessein, le
      # dépôt local de think n'étant pas forcément à jour.
      autoUpgrade = {
        enable = true;
        flake = "github:Nchpg/.dotfiles#server-think";
      };
    };
  };
}
