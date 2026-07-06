{
  config,
  lib,
  pkgs,
  ...
}:

# nix-locate, comma et les suggestions command-not-found, via la base
# hebdomadaire pré-construite de nix-index-database (module HM importé dans
# profiles/default.nix). Remplace le command-not-found des channels, coupés
# dans modules/system/configuration.nix (nix.channel.enable = false).
let
  cfg = config.userSettings.nixIndex;

  # Handler command-not-found maison, partagé par les trois shells. On ne
  # propose que `nix-shell -p <paquet>` : le pavé `nix profile install` du
  # script upstream n'est jamais utilisé ici (tout paquet permanent passe par
  # la config). nix-shell -p marche sans channels : nix.channel.enable = false
  # pose NIX_PATH=nixpkgs=flake:nixpkgs (résolu via le flake registry).
  cnfScript = pkgs.writeShellScript "command-not-found-suggest" ''
    cmd=$1
    # Recherche uniquement sur un vrai terminal : pas de latence nix-locate
    # dans les scripts/pipes (même garde que le script upstream).
    if [ ! -t 2 ]; then
      echo "$cmd: command not found" >&2
      exit 127
    fi

    attrs=$(${config.programs.nix-index.package}/bin/nix-locate \
      --minimal --no-group --type x --type s --whole-name --at-root \
      "/bin/$cmd" 2>/dev/null | head -5)

    if [ -z "$attrs" ]; then
      echo "$cmd: command not found" >&2
      exit 127
    fi

    echo "$cmd: command not found. Run it once with:" >&2
    while IFS= read -r attr; do
      # `.out` (output par défaut) est du bruit ; les autres outputs (.bin,
      # ...) restent nécessaires pour cibler le bon.
      echo "  nix-shell -p ''${attr%.out}" >&2
    done <<<"$attrs"
    exit 127
  '';
in
{
  options = {
    userSettings.nixIndex = {
      enable = lib.mkEnableOption "nix-index (nix-locate, comma, suggestions command-not-found)";
    };
  };

  config = lib.mkIf cfg.enable {
    # Installe nix-index (base pré-construite incluse) : `nix-locate bin/foo`
    # → quel paquet fournit ce fichier. Les intégrations shell upstream sont
    # coupées au profit du handler maison (cnfScript ci-dessus).
    programs.nix-index = {
      enable = true;
      enableBashIntegration = false;
      enableZshIntegration = false;
      enableFishIntegration = false;
    };
    # `, cmd args` : exécute un programme une fois, sans l'installer.
    programs.nix-index-database.comma.enable = true;

    # Hooks command-not-found des trois shells → cnfScript. Chaque shell a son
    # nom de fonction ; sans effet sur les shells non activés par le user.
    programs.bash.initExtra = ''
      command_not_found_handle() {
        ${cnfScript} "$@"
      }
    '';
    programs.zsh.initContent = ''
      command_not_found_handler() {
        ${cnfScript} "$@"
      }
    '';
    programs.fish.functions.fish_command_not_found = ''
      ${cnfScript} $argv
    '';
  };
}
