{
  config,
  lib,
  pkgs-unstable,
  myLib,
  ...
}:

let
  cfg = config.userSettings.agents.mammouthCode;

  # Version, URL + hash épinglés automatiquement par update.sh
  pinned = lib.importJSON ./pinned.json;

  # Binaire précompilé (fork d'OpenCode) en release GitHub, pas npm/nixpkgs :
  # autoPatchelfHook patche l'interpréteur ELF vers le glibc de nixpkgs.
  mammouth-code = cfg.pkgs.stdenv.mkDerivation {
    pname = "mammouth-code";
    version = pinned.version;

    src = myLib.packaging.fetchPinned cfg.pkgs ./pinned.json;

    nativeBuildInputs = [ cfg.pkgs.autoPatchelfHook ];
    dontBuild = true;
    # Exécutable Bun single-file : le JS de l'app est un trailer après le
    # binaire bun. Le strip par défaut l'arrache (mammouth affichait le CLI
    # générique de Bun au lieu de l'app).
    dontStrip = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      install -m755 bin/mammouth $out/bin/mammouth
      runHook postInstall
    '';

    meta = with lib; {
      description = "Mammouth Code — agent de code IA en terminal (fork d'OpenCode)";
      homepage = "https://github.com/mammouth-ai/code";
      platforms = [ "x86_64-linux" ];
      mainProgram = "mammouth";
    };
  };
in
{
  options.userSettings.agents.mammouthCode = {
    enable = lib.mkEnableOption "Mammouth Code CLI";
    pkgs = myLib.mkPkgsOption {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ mammouth-code ];
  };
}
