{ config, lib, ... }:

let
  cfg = config.userSettings.agents;

  skillNames = builtins.attrNames (
    lib.filterAttrs (_name: type: type == "directory") (builtins.readDir ./.)
  );

  # recursive : sinon Claude Code ne liste pas les skills (scan isDirectory()).
  mkSkillFiles =
    base:
    lib.listToAttrs (
      map (
        name:
        lib.nameValuePair "${base}/${name}" {
          source = ./. + "/${name}";
          recursive = true;
        }
      ) skillNames
    );
in
{
  options.userSettings.agents.skills.enable =
    lib.mkEnableOption "skills partagées entre agents de code"
    // {
      default =
        cfg.claude.enable
        || cfg.kimiCode.enable
        || cfg.mammouthCode.enable
        || cfg.opencode.enable
        || cfg.gemini.enable
        || cfg.mistral.enable
        || cfg.codex.enable;
    };

  config = lib.mkIf cfg.skills.enable {
    home.file = lib.mkMerge [
      (mkSkillFiles ".claude/skills")
      (mkSkillFiles ".agents/skills")
      (mkSkillFiles ".vibe/skills")
    ];
  };
}
