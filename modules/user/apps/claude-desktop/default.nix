{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.apps.claudeDesktop;

  pinned = lib.importJSON ./pinned.json;

  pname = "claude-desktop";
  appId = "com.anthropic.Claude";

  src = myLib.packaging.fetchPinned cfg.pkgs ./pinned.json;

  unpacked = cfg.pkgs.stdenvNoCC.mkDerivation {
    pname = "${pname}-unpacked";
    inherit (pinned) version;
    inherit src;
    nativeBuildInputs = [ cfg.pkgs.dpkg ];
    # chrome-sandbox est setuid, refusé par le sandbox de build.
    unpackPhase = "dpkg-deb --fsys-tarfile $src | tar -x --no-same-owner --no-same-permissions";
    installPhase = "cp -r usr $out";
    dontFixup = true;
  };

  ovmfDebian = cfg.pkgs.runCommand "ovmf-debian-layout" { } ''
    mkdir -p $out/share/OVMF
    ln -s ${cfg.pkgs.OVMF.fd}/FV/OVMF_CODE.fd ${cfg.pkgs.OVMF.fd}/FV/OVMF_VARS.fd $out/share/OVMF/
  '';

  app = cfg.pkgs.buildFHSEnv {
    inherit pname;
    inherit (pinned) version;

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

        qemu_kvm
        virtiofsd
        ovmfDebian
      ];

    runScript = cfg.pkgs.writeShellScript "claude-desktop-run" ''
      exec ${unpacked}/lib/claude-desktop/claude-desktop --password-store=gnome-libsecret "$@"
    '';

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
