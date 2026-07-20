{
  config,
  lib,
  pkgs,
  ...
}:

# Remplace le command-not-found des channels, coupés dans
# modules/system/configuration.nix (nix.channel.enable = false).
let
  cfg = config.userSettings.nixIndex;

  # Ne propose que `nix-shell -p <paquet>` (pas `nix profile install`, jamais
  # utilisé ici). Marche sans channels : NIX_PATH=nixpkgs=flake:nixpkgs.
  cnfScript = pkgs.writeShellScript "command-not-found-suggest" ''
    cmd=$1
    # Vrai terminal seulement : pas de latence nix-locate dans les scripts/pipes.
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
    # Intégrations shell upstream coupées au profit de cnfScript ci-dessous.
    programs.nix-index = {
      enable = true;
      enableBashIntegration = false;
      enableZshIntegration = false;
      enableFishIntegration = false;
    };
    programs.nix-index-database.comma.enable = true;

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
