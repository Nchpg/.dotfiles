{
  config,
  lib,
  myLib,
  ...
}:

# Claude Desktop (beta Linux officielle d'Anthropic). Pas dans nixpkgs :
# Anthropic ne publie qu'un .deb pour Debian/Ubuntu, empaqueté ici tel quel
# (épinglé par pinned.json, bumpé par update.sh).
#
# Lancé dans un environnement FHS plutôt que patché binaire par binaire : le
# .deb embarque Electron, des modules natifs (node-pty, claude-native) et des
# exécutables annexes qui attendent tous les bibliothèques sous /usr/lib.
let
  cfg = config.userSettings.apps.claudeDesktop;

  # Version, URL + hash épinglés automatiquement par update.sh
  pinned = lib.importJSON ./pinned.json;

  pname = "claude-desktop";
  # Préfixe du .desktop et du type MIME dans le .deb.
  appId = "com.anthropic.Claude";

  src = myLib.packaging.fetchPinned cfg.pkgs ./pinned.json;

  # Arborescence /usr du .deb, sans patchelf : c'est le FHS qui fournit les
  # bibliothèques.
  unpacked = cfg.pkgs.stdenvNoCC.mkDerivation {
    pname = "${pname}-unpacked";
    inherit (pinned) version;
    inherit src;
    nativeBuildInputs = [ cfg.pkgs.dpkg ];
    # chrome-sandbox est setuid dans le .deb, refusé dans le bac à sable de
    # build : on extrait sans les bits spéciaux (Chromium se rabat sur son
    # bac à sable par namespaces).
    unpackPhase = "dpkg-deb --fsys-tarfile $src | tar -x --no-same-owner --no-same-permissions";
    installPhase = "cp -r usr $out";
    dontFixup = true;
  };

  # Cowork lance sa VM avec QEMU et cherche le firmware UEFI aux chemins
  # Debian en dur (/usr/share/OVMF/OVMF_CODE.fd, et le modèle de variables
  # EFI à côté, seulement lu). Ce paquet les y pose dans le FHS. /dev/kvm et
  # /dev/vhost-vsock doivent être accessibles en lecture/écriture : c'est
  # déjà le cas sur NixOS (0666).
  ovmfDebian = cfg.pkgs.runCommand "ovmf-debian-layout" { } ''
    mkdir -p $out/share/OVMF
    ln -s ${cfg.pkgs.OVMF.fd}/FV/OVMF_CODE.fd ${cfg.pkgs.OVMF.fd}/FV/OVMF_VARS.fd $out/share/OVMF/
  '';

  app = cfg.pkgs.buildFHSEnv {
    inherit pname;
    inherit (pinned) version;

    # Dépendances du paquet (Depends/Recommends du .deb) + ce qu'Electron
    # charge sans le déclarer.
    targetPkgs =
      pkgs: with pkgs; [
        alsa-lib
        at-spi2-atk
        at-spi2-core
        cairo
        cups
        dbus
        expat
        glib
        gtk3
        libayatana-appindicator
        libdrm
        libgbm
        libGL
        libnotify
        libsecret
        libuuid
        libx11
        libxcb
        libxcomposite
        libxdamage
        libxext
        libxfixes
        libxkbcommon
        libxkbfile
        libxrandr
        libxshmfence
        libxtst
        mesa
        nspr
        nss
        pango
        pipewire
        systemd
        vulkan-loader
        xdg-utils
        bubblewrap
        socat

        # Cowork (Recommends du .deb) : virtiofsd attendu dans /usr/bin,
        # qemu-system-x86_64 cherché dans le PATH.
        qemu_kvm
        virtiofsd
        ovmfDebian
      ];

    # Electron choisit son coffre à secrets d'après XDG_CURRENT_DESKTOP : sous
    # sway, inconnu, il se rabat sur du texte en clair (basic_text) et l'app
    # ne garde ni la connexion ni les secrets. On force gnome-keyring, qui
    # tourne déjà (Secret Service, déverrouillé au login par PAM).
    runScript = cfg.pkgs.writeShellScript "claude-desktop-run" ''
      exec ${unpacked}/lib/claude-desktop/claude-desktop --password-store=gnome-libsecret "$@"
    '';

    # .desktop du paquet : Exec pointe le binaire nu, à remplacer par le
    # wrapper (seul à monter l'environnement FHS). Le type MIME (.mcpb,
    # .skill) est pris en compte par home-manager via share/mime.
    extraInstallCommands = ''
      install -Dm444 ${unpacked}/share/applications/${appId}.desktop \
        $out/share/applications/${appId}.desktop
      substituteInPlace $out/share/applications/${appId}.desktop \
        --replace-fail 'Exec=claude-desktop' "Exec=$out/bin/${pname}"
      cp -r ${unpacked}/share/icons $out/share/
      install -Dm444 ${unpacked}/lib/claude-desktop/resources/linux-mime/${appId}.xml \
        $out/share/mime/packages/${appId}.xml
    '';
  };
in
{
  options.userSettings.apps.claudeDesktop = {
    enable = lib.mkEnableOption "Claude Desktop (app officielle, beta Linux)";

    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ app ];
  };
}
