{
  lib,
  config,
  pkgs-stable,
  myLib,
  ...
}:

# `dots` : point d'entrée unique pour les commandes du dépôt (rebuild, update,
# theme, genclean, secrets). Sans argument, un menu gum : on choisit la
# commande, puis un des usages courants (avec son explication), ou on tape ses
# propres arguments. `dots <commande> …` relaie tel quel, `dots help` liste
# tout avec les exemples.
#
# Le catalogue est déclaré par les commandes elles-mêmes (option
# systemSettings.commands, cf. ../default.nix) : une commande absente de ce
# système (`theme` sans Stylix) n'y est simplement pas.
let
  # Le catalogue : ce que chaque module de commande a déclaré (cf.
  # ../default.nix), dans l'ordre de `order`.
  commands = lib.sort (a: b: a.order < b.order) (
    lib.mapAttrsToList (name: c: c // { inherit name; }) config.systemSettings.commands
  );

  # Une ligne par entrée, champs séparés par des tabulations :
  #   cmd  <nom>  <description>
  #   ex   <nom>  <ligne de commande>  <explication>
  catalog = lib.concatMapStrings (
    c:
    "cmd\t${c.name}\t${c.desc}\n"
    + lib.concatMapStrings (
      e: "ex\t${c.name}\t${builtins.elemAt e 0}\t${builtins.elemAt e 1}\n"
    ) c.examples
  ) commands;
in
{
  # Pas une commande du PATH : le script du dépôt, ~/.dotfiles/init.sh. Inscrit
  # ici, faute de module à lui.
  systemSettings.commands.init = {
    desc = "prépare cette machine : clés, secrets, hooks, inscription";
    order = 6;
    examples = [
      [
        "init"
        "vérifie et rattrape ce qui manque (sans risque si déjà prête)"
      ]
    ];
  };

  environment.systemPackages = [
    (pkgs-stable.writeShellApplication {
      name = "dots";
      runtimeInputs = [
        pkgs-stable.gum
        pkgs-stable.git
      ];
      # Le script lui-même : dots.sh, à côté. Seules les valeurs tirées de la
      # config viennent d'ici, en préambule.
      text = ''
        # Palette gum, la même que `update` & co (cf. lib/mk-gum-env.nix).
        ${myLib.mkGumEnv {
          colors = if config.stylix.enable then config.lib.stylix.colors else null;
        }}
        catalog=$(cat <<'CATALOG'
        ${catalog}CATALOG
        )

        ${myLib.flakeVar}
      ''
      + builtins.readFile ./dots.sh;
    })
  ];
}
