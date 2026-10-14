{
  config,
  pkgs-stable,
  myLib,
  ...
}:

{
  # Entrée du catalogue de `dots` (cf. ../default.nix).
  systemSettings.commands.genclean = {
    desc = "nettoie les générations, GC, optimise le store";
    order = 4;
    examples = [
      [
        "genclean"
        "choix des étapes d'avance, puis tout s'enchaîne"
      ]
    ];
  };

  # Enrobe scripts/genclean.sh du dépôt pour le lancer depuis n'importe où, avec
  # gum et la palette Stylix pour ses menus (même rendu que `update`).
  environment.systemPackages = [
    (myLib.mkRepoCommand {
      pkgs = pkgs-stable;
      name = "genclean";
      gumEnv = myLib.mkGumEnv {
        colors = if config.stylix.enable then config.lib.stylix.colors else null;
        inherit (pkgs-stable) gum;
      };
    })
  ];
}
