{ config, lib, ... }:

# Skills partagées entre agents de code (format SKILL.md commun à tous : YAML
# frontmatter + markdown). Un seul dossier source (./skills), dupliqué (symlinks
# du store) vers chaque chemin de découverte que les agents activés savent
# lire :
#   - ~/.claude/skills/  : Claude Code, ET lu nativement par kimi-code et
#     opencode/mammouth-code (compat Claude intégrée chez ces deux-là) ;
#   - ~/.agents/skills/  : chemin générique émergent (spec cross-outils), lu
#     par kimi-code (groupe "generic"), Antigravity/gemini ET codex (depuis
#     déc. 2025 — vérifié sur developers.openai.com, pas de compat .claude/
#     chez lui, seulement .agents/) ;
#   - ~/.vibe/skills/    : mistral-vibe, qui ne connaît ni .claude/ ni .agents/
#     au niveau utilisateur.
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
      # Suit automatiquement les agents qui savent en profiter : pas de bascule
      # à penser à activer séparément à chaque nouvel agent.
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
