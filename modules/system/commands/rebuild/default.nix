{
  config,
  pkgs-stable,
  target,
  myLib,
  ...
}:

{
  # Entrée du catalogue de `dots` (cf. ../default.nix).
  systemSettings.commands.rebuild = {
    desc = "reconstruit et active le système";
    order = 1;
    examples = [
      [
        "rebuild"
        "rebuild de la cible de ce système"
      ]
      [
        "rebuild -u"
        "update (au choix) puis rebuild"
      ]
      [
        "rebuild -y"
        "sans confirmation (working tree sale…)"
      ]
      [
        "rebuild -V <dark|light>"
        "rebuild dans une variante de thème"
      ]
    ];
  };

  # Enrobe scripts/rebuild.sh, qui fait tout le parsing (formes courtes et
  # longues, --help) : l'enveloppe ne pose que les DÉFAUTS. Profil/host/variante
  # par défaut = ceux de la config qui a construit ce système (specialArg
  # `target`, plus robuste que parser le hostname). Variante par défaut = celle
  # du système courant : `rebuild` seul reste dans la même dark/light, sans
  # fichier d'état (cf. `theme`).
  environment.systemPackages = [
    # Diff des paquets entre générations, affiché par rebuild.sh après le switch.
    pkgs-stable.nvd

    (myLib.mkRepoCommand {
      pkgs = pkgs-stable;
      name = "rebuild";
      # Pour `-u` : rebuild.sh lance update.sh, qui a besoin de gum.
      gumEnv = myLib.mkGumEnv {
        colors = if config.stylix.enable then config.lib.stylix.colors else null;
        inherit (pkgs-stable) gum;
      };
      preamble = ''
        export REBUILD_DEFAULT_PROFILE="${target.profile}"
        export REBUILD_DEFAULT_HOST="${target.host}"
        export REBUILD_DEFAULT_VARIANT="${target.variant}"
      '';
    })
  ];
}
