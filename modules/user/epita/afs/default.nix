{
  config,
  lib,
  myLib,
  ...
}:

# AFS du CRI (EPITA) depuis l'extérieur de l'école, via la passerelle SSH.
#
# Trois choses seulement, mais aucune ne marche sans les deux autres :
#
#   1. Un ssh COMPILÉ AVEC GSSAPI. Depuis 24.11, le paquet `openssh` de nixpkgs
#      est construit sans, donc le ssh du système ignore purement et simplement
#      `GSSAPIAuthentication yes` — la passerelle répond alors « Permission
#      denied » comme si le ticket n'existait pas. D'où `openssh_gssapi`, posé
#      sur `programs.ssh.package` (donc pour TOUT ssh de ce compte, cf. plus bas).
#   2. Un bloc Host qui demande GSSAPI *et rien d'autre*. Le CRI insiste : si le
#      client tente d'abord l'agent ou une clé publique, le serveur tranche sur
#      cette identité-là et on tombe sur un « Permission denied » trompeur alors
#      que le ticket Kerberos est bon. On coupe donc explicitement les clés.
#   3. Un ticket Kerberos vivant (`kinit`). Il expire en quelques jours, et
#      quand il meurt le point de montage reste là mais répond en erreur : il
#      faut démonter, reprendre un ticket, remonter — c'est exactement ce que
#      fait `afs mount` quand on le relance.
#
# PAS de krb5.conf ici, et ce n'est pas un oubli : le realm CRI.EPITA.FR publie
# ses enregistrements de découverte (`_kerberos._tcp.cri.epita.fr` -> SRV
# kerberos.cri.epita.fr, `_kerberos.cri.epita.fr` -> TXT "CRI.EPITA.FR"), et MIT
# krb5 les suit par défaut. Écrire les KDC en dur ne ferait que figer une
# infrastructure qui n'est pas la nôtre.
let
  cfg = config.userSettings.epita.afs;

  # sshfs lance `ssh` lui-même, et c'est CELUI QU'IL A ÉTÉ COMPILÉ AVEC, pas
  # celui du PATH : le paquet nixpkgs pointe le chemin du store d'openssh à la
  # construction. Sans cet override, le montage échoue même avec un ticket
  # valide et un ~/.ssh/config parfait, puisque ce ssh-là n'a pas GSSAPI.
  #
  # La doc du CRI passe par une gymnastique `callPackage`/`newScope` : plus
  # nécessaire, `sshfs.override` expose directement `openssh`.
  sshfs = cfg.pkgs.sshfs.override { openssh = cfg.pkgs.openssh_gssapi; };

  afs = cfg.pkgs.writeShellApplication {
    name = "afs";
    runtimeInputs = [
      cfg.pkgs.krb5 # kinit, klist, kdestroy
      sshfs
      cfg.pkgs.coreutils
      cfg.pkgs.gawk # lecture de /proc/self/mountinfo
    ];
    # `fusermount3` N'EST PAS dans cette liste, volontairement : il doit venir
    # du wrapper setuid de /run/wrappers/bin (posé par NixOS), seul autorisé à
    # (dé)monter pour un utilisateur. Le binaire de `pkgs.fuse3`, lui, échouerait
    # sur les permissions.

    text = ''
      mount_point=${lib.escapeShellArg cfg.mountPoint}
      remote=${lib.escapeShellArg "${cfg.gateway}:${cfg.remotePath}"}
      principal=${lib.escapeShellArg "${cfg.login}@${cfg.realm}"}

      # Tout ce qui suit interroge /proc/self/mountinfo au lieu d'appeler
      # `mountpoint`(8), et ce n'est pas une coquetterie : un stat() sur un
      # montage sshfs dont la session est morte ne revient JAMAIS (le processus
      # part en D, insensible jusqu'au SIGKILL). Comme le point de montage est
      # dans le home, ça gèle tout ce qui liste le home — Thunar, le portail xdg
      # donc le sélecteur de fichiers de Discord, un shell, un agent. mountinfo
      # est lu depuis le noyau et répond toujours.
      mount_id() {
        awk -v mp="$mount_point" '$5 == mp { split($3, dev, ":"); print dev[2]; exit }' /proc/self/mountinfo
      }

      is_mounted() {
        [ -n "$(mount_id)" ]
      }

      # Démontage qui aboutit même quand la session ssh est morte :
      #   1. `abort` du connecteur FUSE : les requêtes en attente reçoivent EIO
      #      au lieu d'attendre indéfiniment, ce qui réveille d'un coup tous les
      #      processus bloqués. C'est l'étape qui dégèle l'environnement.
      #   2. démontage paresseux : un shell dont le cwd est resté dans le
      #      montage le garde « busy », et -z détache quand même l'arborescence.
      force_umount() {
        conn=$(mount_id)
        if [ -n "$conn" ] && [ -w "/sys/fs/fuse/connections/$conn/abort" ]; then
          echo 1 > "/sys/fs/fuse/connections/$conn/abort"
        fi
        fusermount3 -uz "$mount_point" 2>/dev/null || true
      }

      ticket() {
        # `klist -s` : silencieux, statut non-zéro si aucun ticket valide. On ne
        # redemande donc le mot de passe Forge que quand il le faut vraiment.
        # -f : ticket TRANSFÉRABLE, sans quoi GSSAPIDelegateCredentials n'a rien
        # à déléguer et la passerelle ne peut pas obtenir de jeton AFS.
        klist -s || kinit -f "$principal"
      }

      case "''${1:-mount}" in
        mount)
          ticket
          mkdir -p "$mount_point"
          if is_mounted; then
            echo "afs : déjà monté sur $mount_point"
            exit 0
          fi
          # `reconnect` relance la session quand elle tombe, mais seul il ne
          # suffit pas : sans keepalive, ssh ne s'aperçoit jamais que le pair a
          # disparu (veille, changement de réseau, VPN coupé). Le montage reste
          # alors vivant pour le noyau avec plus personne au bout, et la
          # première lecture du home gèle la machine. Les options qui suivent
          # bornent l'attente à ~45 s, après quoi sshfs reconnecte.
          sshfs "$remote" "$mount_point" \
            -o reconnect \
            -o ServerAliveInterval=15 \
            -o ServerAliveCountMax=3 \
            -o ConnectTimeout=10
          echo "afs : monté sur $mount_point"
          ;;
        umount|unmount)
          force_umount
          echo "afs : démonté"
          ;;
        ticket)
          # Force un ticket neuf : le cas du ticket expiré alors que le montage
          # tient encore. Démonter d'abord, sinon sshfs garde sa session morte.
          if is_mounted; then force_umount; fi
          kinit -f "$principal"
          ;;
        status)
          klist || true
          echo
          if is_mounted; then
            echo "montage : $mount_point"
          else
            echo "montage : aucun"
          fi
          ;;
        *)
          echo "usage: afs [mount|umount|ticket|status]" >&2
          exit 1
          ;;
      esac
    '';
  };
in
{
  options.userSettings.epita.afs = {
    enable = lib.mkEnableOption "accès à l'AFS du CRI depuis l'extérieur (passerelle SSH + Kerberos)";
    pkgs = myLib.mkPkgsOption { inherit lib config; };

    login = lib.mkOption {
      type = lib.types.str;
      example = "xavier.login";
      description = "Login Forge, celui du principal Kerberos et du chemin AFS.";
    };

    realm = lib.mkOption {
      type = lib.types.str;
      default = "CRI.EPITA.FR";
      description = "Realm Kerberos passé à kinit.";
    };

    gateway = lib.mkOption {
      type = lib.types.str;
      default = "ssh.cri.epita.fr";
      description = "Passerelle SSH du CRI. Sert aussi de motif `Host` dans ~/.ssh/config.";
    };

    remotePath = lib.mkOption {
      type = lib.types.str;
      default =
        let
          l = lib.toLower cfg.login;
        in
        "/afs/cri.epita.fr/user/${lib.substring 0 1 l}/${lib.substring 0 2 l}/${l}/u/";
      defaultText = "/afs/cri.epita.fr/user/<initiale>/<2 premières lettres>/<login>/u/";
      description = ''
        Répertoire AFS monté. Le défaut reproduit le rangement du CRI
        (`.../user/x/xa/xavier.login/u/`) ; à surcharger pour monter autre chose
        que son propre `u/`.
      '';
    };

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/mnt/afs";
      defaultText = "\${config.home.homeDirectory}/mnt/afs";
      description = ''
        Point de montage local, créé à la volée par `afs mount`.

        Sous `mnt/` et pas directement dans le home, délibérément : lister un
        répertoire appelle `stat()` sur chacune de ses entrées, et sur un
        montage réseau qui ne répond plus cet appel attend. Tant que le montage
        est à la racine du home, la moindre ouverture du sélecteur de fichiers
        (Thunar, le portail xdg, donc Discord) ou un `ls ~` se fige. Une
        indirection suffit à immuniser le home : `mnt` est un vrai répertoire
        local, instantané, et seul un passage explicite dedans peut attendre.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.login != "";
        message = "userSettings.epita.afs.login doit porter le login Forge : c'est lui qui donne le principal Kerberos ET le chemin AFS.";
      }
    ];

    # POUR TOUT SSH DE CE COMPTE, pas seulement la passerelle : `programs.ssh`
    # n'a qu'un paquet, et sshfs a le sien (ci-dessus). Sans conséquence — c'est
    # le même OpenSSH avec une méthode d'authentification de plus, jamais tentée
    # face à un serveur qui ne l'annonce pas.
    programs.ssh.package = cfg.pkgs.openssh_gssapi;

    # Passe par le module ssh du dépôt plutôt que par `programs.ssh.settings` :
    # un seul endroit écrit ~/.ssh/config, et le bloc se lit à côté des autres
    # hôtes déclarés par le profil.
    userSettings.ssh.hosts.${cfg.gateway} = {
      User = cfg.login;

      GSSAPIAuthentication = "yes";
      # La délégation est le point entier de l'affaire : la passerelle a besoin
      # de NOTRE ticket pour obtenir un jeton AFS en notre nom. Sans elle, on se
      # connecte mais tout /afs répond « Permission denied ».
      GSSAPIDelegateCredentials = "yes";

      # GSSAPI et rien d'autre. Une clé publique ou un agent qui répond avant
      # donne au serveur une identité qui n'a aucun droit sur l'AFS, et l'erreur
      # ressemble alors à un problème de ticket.
      PreferredAuthentications = "gssapi-with-mic";
      PubkeyAuthentication = "no";
      IdentityAgent = "none";
    };

    home.packages = [
      afs
      cfg.pkgs.krb5 # kinit/klist utilisables à la main, hors du wrapper
      sshfs
    ];
  };
}
