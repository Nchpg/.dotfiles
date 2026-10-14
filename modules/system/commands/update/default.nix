{
  config,
  pkgs-stable,
  myLib,
  ...
}:

{
  # Entrée du catalogue de `dots` (cf. ../default.nix).
  systemSettings.commands.update = {
    desc = "met à jour modules et inputs du flake (sans rebuild)";
    order = 2;
    examples = [
      [
        "update -c"
        "liste ce qui a une mise à jour, ne modifie rien"
      ]
      [
        "update"
        "vérifie tout, puis coche quoi mettre à jour"
      ]
      [
        "update -y"
        "applique la sélection par défaut sans question"
      ]
      [
        "update <nom>"
        "restreint aux modules/inputs contenant ce nom"
      ]
    ];
  };

  # Enrobe scripts/update.sh du dépôt pour le lancer depuis n'importe où, avec gum
  # et la palette Stylix (cf. lib/mk-repo-command.nix, lib/mk-gum-env.nix).
  environment.systemPackages = [
    (myLib.mkRepoCommand {
      pkgs = pkgs-stable;
      name = "update";
      gumEnv = myLib.mkGumEnv {
        colors = if config.stylix.enable then config.lib.stylix.colors else null;
        inherit (pkgs-stable) gum;
      };
    })
  ];
}
