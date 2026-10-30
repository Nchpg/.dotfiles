{
  config,
  lib,
  ...
}:

let
  herdrCfg = config.userSettings.agents.herdr;
  cfg = herdrCfg.app;
  inherit (herdrCfg) pkgs;

  pinned = lib.importJSON ./pinned.json;

  # Binaire statique : rien à patcher. `hc` est son nom court.
  core = pkgs.stdenvNoCC.mkDerivation {
    pname = "herdr-core";
    version = pinned.core_version;

    src = pkgs.fetchurl {
      url = pinned.core_url;
      hash = pinned.core_hash;
    };
    sourceRoot = ".";

    installPhase = ''
      runHook preInstall
      install -Dm755 herdr-core $out/bin/herdr-core
      ln -s herdr-core $out/bin/hc
      runHook postInstall
    '';

    meta = {
      description = "herdr-core — démon qui garde terminaux et agents en vie pour l'app Herdr";
      homepage = "https://herdr.dev";
      license = lib.licenses.asl20;
      platforms = [ "x86_64-linux" ];
      mainProgram = "herdr-core";
    };
  };

  app = pkgs.stdenvNoCC.mkDerivation {
    pname = "herdr-app";
    version = pinned.version;

    src = pkgs.fetchurl {
      inherit (pinned) url hash;
    };

    nativeBuildInputs = with pkgs; [
      autoPatchelfHook
      makeWrapper
      copyDesktopItems
    ];
    buildInputs = with pkgs; [
      libgcc
      libxcb
      libxkbcommon
    ];

    desktopItems = [
      (pkgs.makeDesktopItem {
        name = "herdr-app";
        desktopName = "Herdr";
        comment = "Terminals and coding agents that keep running";
        exec = "herdr-app";
        icon = "herdr-app";
        categories = [ "Development" ];
        startupWMClass = "herdr-app";
      })
    ];

    installPhase = ''
      runHook preInstall
      install -Dm755 herdr-app $out/libexec/herdr-app
      install -Dm644 herdr-app.svg $out/share/icons/hicolor/scalable/apps/herdr-app.svg
      # Chargées à l'exécution (dlopen), invisibles pour autoPatchelf.
      # herdr-core dans le PATH : l'app n'en installe pas un dans ~/.local/bin.
      makeWrapper $out/libexec/herdr-app $out/bin/herdr-app \
        --prefix LD_LIBRARY_PATH : ${
          lib.makeLibraryPath (
            with pkgs;
            [
              libglvnd
              vulkan-loader
              wayland
              libxkbcommon
            ]
          )
        } \
        --prefix PATH : ${lib.makeBinPath [ core ]}
      runHook postInstall
    '';

    meta = {
      description = "Herdr — app de bureau pour terminaux et agents de code persistants";
      homepage = "https://herdr.dev";
      license = lib.licenses.asl20;
      platforms = [ "x86_64-linux" ];
      mainProgram = "herdr-app";
    };
  };
in
{
  options.userSettings.agents.herdr.app.enable =
    lib.mkEnableOption "Herdr app (bêta) : l'app de bureau et son démon herdr-core";

  config = lib.mkIf (herdrCfg.enable && cfg.enable) {
    home.packages = [
      app
      core # `hc` dans le terminal
    ];
  };
}
