{ config, lib, ... }:

# Un seul dossier source (./skills, format SKILL.md), dupliqué vers chaque
# chemin de découverte lu par les agents activés :
#   - ~/.claude/skills/ : Claude Code, kimi-code, opencode/mammouth-code (compat)
#   - ~/.agents/skills/ : kimi-code, Antigravity/gemini, codex (pas .claude/)
#   - ~/.vibe/skills/   : mistral-vibe (ni .claude/ ni .agents/)
let
  cfg = config.userSettings.agents;

  skillNames = builtins.attrNames (
    lib.filterAttrs (_name: type: type == "directory") (builtins.readDir ./skills)
  );

  mkSkillFiles =
    base:
    lib.listToAttrs (
      map (name: lib.nameValuePair "${base}/${name}" { source = ./skills + "/${name}"; }) skillNames
    );
in
{
  options.userSettings.agents.skills.enable =
    lib.mkEnableOption "skills partagées entre agents de code"
    // {
      # Suit automatiquement les agents activés.
      default =
        cfg.claude.enable
        || cfg.kimiCode.enable
        || cfg.mammouthCode.enable
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
