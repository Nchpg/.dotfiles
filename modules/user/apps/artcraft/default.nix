{
  config,
  lib,
  myLib,
  ...
}:

# ArtCraft Launcher : installe et met à jour la Craft App Suite (PhotoCraft,
# VectorCraft, FilmCraft, ... clones open source d'Adobe). Gaté par profil.
#
# Partage des rôles : Nix gère le LAUNCHER (épinglé par pinned.json, bumpé par
# update.sh), le launcher gère les APPS (AppImages dans ~/Applications, MAJ en
# un clic). Les apps sortent quasi tous les jours en alpha : les épingler une
# par une ferait un bump de hash par jour et par app.
#
# Pourquoi le launcher n'écrase pas sa version Nix : son auto-update ne
# s'active que lancé en AppImage ($APPIMAGE) ou en .deb/.rpm dans /usr/bin.
# Extrait par wrapType2, ni l'un ni l'autre : il affiche juste un bandeau
# « Download » quand une version sort, à ignorer (le bump passe par update.sh).
let
  cfg = config.userSettings.apps.artcraft;

  # Version + hash épinglés automatiquement par update.sh
  pinned = builtins.fromJSON (builtins.readFile ./pinned.json);

  pname = "artcraft-launcher";
  # Préfixe des .desktop, icônes et unités dans l'AppImage.
  appId = "ai.storyteller.artcraft-launcher";

  src = cfg.pkgs.fetchurl {
    url = "https://github.com/storytold/craft-launcher/releases/download/v${pinned.version}/artcraft-launcher-${pinned.version}-linux-x86_64.AppImage";
    hash = pinned.sha256;
  };

  extracted = cfg.pkgs.appimageTools.extract {
    inherit pname src;
    inherit (pinned) version;
  };

  launcher = cfg.pkgs.appimageTools.wrapType2 {
    inherit pname src;
    inherit (pinned) version;

    # Les apps lancées par le launcher (« Open ») tournent DANS son bac à
    # sable bwrap, où le fusermount setuid ne marche pas : leur AppImage ne
    # peut pas monter son squashfs (« No suitable fusermount binary »). Ce
    # mode l'extrait dans /tmp à la place, au prix d'un démarrage un peu plus
    # lent.
    profile = ''
      export APPIMAGE_EXTRACT_AND_RUN=1
    '';

    # .desktop de l'AppImage : Exec pointe le binaire interne, à remplacer par
    # le wrapper (seul à monter l'environnement FHS).
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

    # Entrées de menu des apps installées par le launcher (cf.
    # sync-desktop.sh) : resynchro à chaque install/MAJ/désinstall dans
    # ~/Applications, et une fois à la connexion pour rattraper l'existant.
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
