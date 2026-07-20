{
  config,
  lib,
  pkgs-unstable,
  ...
}:

let
  cfg = config.userSettings.agents.mammouthCode;

  # Charge la version + le hash épinglés automatiquement par update.sh
  pinned = builtins.fromJSON (builtins.readFile ./pinned.json);

  # Binaire précompilé (fork d'OpenCode) distribué en release GitHub, pas en
  # paquet npm ni nixpkgs (cf. update.sh) : `fetchurl` + hash vérifié par Nix
  # (FOD), `autoPatchelfHook` pour patcher l'interpréteur ELF vers le glibc de
  # nixpkgs (le binaire upstream cible un Linux générique, pas NixOS).
  mammouth-code = cfg.pkgs.stdenv.mkDerivation {
    pname = "mammouth-code";
    version = pinned.version;

    src = cfg.pkgs.fetchurl {
      url = "https://github.com/mammouth-ai/code/releases/download/v${pinned.version}/mammouth-linux-x64.tar.gz";
      sha256 = pinned.sha256;
    };

    nativeBuildInputs = [ cfg.pkgs.autoPatchelfHook ];
    dontBuild = true;
    # Le binaire est un exécutable Bun single-file : le JS de l'app est ajouté
    # en trailer après le binaire `bun` lui-même. Le strip par défaut de Nix
    # arrache ce trailer, ne laissant que le runtime `bun` nu (constaté : mammouth
    # affichait le CLI générique de Bun au lieu de l'app). Même fix que
    # claude-code-nix pour son propre binaire SEA.
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
    # Défaut sur unstable, comme les autres agents IA de ce dossier.
    pkgs = import ../../../../lib/mk-pkgs-option.nix {
      inherit lib config;
      default = pkgs-unstable;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ mammouth-code ];
  };
}
