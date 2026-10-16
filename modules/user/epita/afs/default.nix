{
  config,
  lib,
  myLib,
  ...
}:

# Pas de krb5.conf : le realm publie ses KDC par DNS (SRV/TXT).
let
  cfg = config.userSettings.epita.afs;

  # sshfs utilise le ssh avec lequel il a été compilé, pas celui du PATH.
  sshfs = cfg.pkgs.sshfs.override { openssh = cfg.pkgs.openssh_gssapi; };

  afs = cfg.pkgs.writeShellApplication {
    name = "afs";
    runtimeInputs = [
      cfg.pkgs.krb5
      sshfs
      cfg.pkgs.coreutils
      cfg.pkgs.gawk
    ];
    # fusermount3 absent volontairement : il doit venir du wrapper setuid de /run/wrappers/bin.

    text = ''
      mount_point=${lib.escapeShellArg cfg.mountPoint}
      remote=${lib.escapeShellArg "${cfg.gateway}:${cfg.remotePath}"}
      principal=${lib.escapeShellArg "${cfg.login}@${cfg.realm}"}

      # /proc/self/mountinfo plutôt que mountpoint(8) : stat() sur un sshfs mort gèle le home.
      mount_id() {
        awk -v mp="$mount_point" '$5 == mp { split($3, dev, ":"); print dev[2]; exit }' /proc/self/mountinfo
      }

      is_mounted() {
        [ -n "$(mount_id)" ]
      }

      # Abort FUSE (EIO aux requêtes en attente) puis démontage paresseux.
      force_umount() {
        conn=$(mount_id)
        if [ -n "$conn" ] && [ -w "/sys/fs/fuse/connections/$conn/abort" ]; then
          echo 1 > "/sys/fs/fuse/connections/$conn/abort"
        fi
        fusermount3 -uz "$mount_point" 2>/dev/null || true
      }

      ticket() {
        # -f : ticket transférable, requis par GSSAPIDelegateCredentials.
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
          # Sans keepalive ssh ne voit jamais le pair disparaître (veille, VPN).
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
          # Ticket neuf : démonter d'abord, sinon sshfs garde sa session morte.
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
      description = "Répertoire AFS monté (défaut : le `u/` de l'utilisateur, rangé comme `.../user/x/xa/xavier.login/u/`).";
    };

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/mnt/afs";
      defaultText = "\${config.home.homeDirectory}/mnt/afs";
      description = ''
        Point de montage local, créé par `afs mount`. Sous `mnt/` et non à la
        racine du home : un montage mort y figerait `ls ~` et les sélecteurs de fichiers.
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

    programs.ssh.package = cfg.pkgs.openssh_gssapi;

    userSettings.ssh.hosts.${cfg.gateway} = {
      User = cfg.login;

      GSSAPIAuthentication = "yes";
      # Sans délégation, tout /afs répond « Permission denied ».
      GSSAPIDelegateCredentials = "yes";

      # GSSAPI uniquement : une clé ou un agent donnerait une identité sans droit sur l'AFS.
      PreferredAuthentications = "gssapi-with-mic";
      PubkeyAuthentication = "no";
      IdentityAgent = "none";
    };

    home.packages = [
      afs
      cfg.pkgs.krb5
      sshfs
    ];
  };
}
