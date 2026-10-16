{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.userSettings.nixIndex;

  cnfScript = pkgs.writeShellScript "command-not-found-suggest" ''
    cmd=$1
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
