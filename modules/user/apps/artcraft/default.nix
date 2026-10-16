{
  config,
  lib,
  myLib,
  ...
}:

# Le bandeau « Download » du launcher est à ignorer : pas d'auto-update hors AppImage natif/.deb/.rpm.
let
  cfg = config.userSettings.apps.artcraft;

  pinned = lib.importJSON ./pinned.json;

  pname = "artcraft-launcher";
  appId = "ai.storyteller.artcraft-launcher";

  src = myLib.packaging.fetchPinned cfg.pkgs ./pinned.json;

  extracted = cfg.pkgs.appimageTools.extract {
    inherit pname src;
    inherit (pinned) version;
  };

  launcher = cfg.pkgs.appimageTools.wrapType2 {
    inherit pname src;
    inherit (pinned) version;

    # EXTRACT_AND_RUN : fusermount setuid ne marche pas dans le bwrap du launcher.
    profile = ''
      export APPIMAGE_EXTRACT_AND_RUN=1

      artcraft_settings="''${XDG_DATA_HOME:-$HOME/.local/share}/${appId}/app.ron"
      if [ -f "$artcraft_settings" ]; then
        ${cfg.pkgs.gnused}/bin/sed -i 's/close_to_tray:true/close_to_tray:false/' "$artcraft_settings"
      else
        ${cfg.pkgs.coreutils}/bin/mkdir -p "$(${cfg.pkgs.coreutils}/bin/dirname "$artcraft_settings")"
        printf '{\n    "settings": "(close_to_tray:false)",\n}\n' >"$artcraft_settings"
      fi
      unset artcraft_settings
    '';

    # Exec doit pointer le wrapper (seul à monter l'environnement FHS).
    extraInstallCommands = ''
      install -Dm444 ${extracted}/usr/share/applications/${appId}.desktop \
        $out/share/applications/${appId}.desktop
      substituteInPlace $out/share/applications/${appId}.desktop \
        --replace-fail 'Exec=artcraft-launcher' "Exec=$out/bin/${pname}"
      cp -r ${extracted}/usr/share/icons $out/share/
    '';
  };

  syncDesktop = cfg.pkgs.writeShellApplication {
    name = "artcraft-sync-desktop";
    runtimeInputs = with cfg.pkgs; [
      coreutils
      findutils
      gnugrep
      gnused
      desktop-file-utils
    ];
    text = builtins.readFile ./sync-desktop.sh;
  };
in
{
  options.userSettings.apps.artcraft = {
    enable = lib.mkEnableOption "ArtCraft Launcher (Craft App Suite, alternatives open source à Adobe)";

    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      launcher
      syncDesktop
    ];

    systemd.user.paths.artcraft-sync-desktop = {
      Unit.Description = "Surveille ~/Applications (apps ArtCraft)";
      Path = {
        PathChanged = "%h/Applications";
        MakeDirectory = true;
      };
      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.artcraft-sync-desktop = {
      Unit.Description = "Entrées de menu des apps ArtCraft (~/Applications)";
      Service = {
        Type = "oneshot";
        ExecStart = "${syncDesktop}/bin/artcraft-sync-desktop";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
