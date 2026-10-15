{
  lib,
  config,
  pkgs-stable,
  target,
  myLib,
  themes,
  ...
}:

# Les commandes du dépôt (rebuild, update, genclean, secrets, dots, theme) :
# UN paquet construit depuis scripts/ (cf. scripts/default.nix), avec les
# valeurs de CE système dans son lib/config.sh.
let
  stylix = config.systemSettings.stylix;

  palette = myLib.uiPalette (if config.stylix.enable then config.lib.stylix.colors else null);

  settings = {
    # Défauts de `rebuild` (et variante actuelle pour `theme`) : la cible qui a
    # construit ce système, plus robuste que de parser le hostname. `rebuild`
    # seul reste donc dans la même variante dark/light, sans fichier d'état.
    DOTS_PROFILE = target.profile;
    DOTS_HOST = target.host;
    DOTS_VARIANT = target.variant;

    # `secrets` : nix et éditeur FIGÉS AU BUILD, jamais résolus depuis ton
    # environnement — sops les exécute sous sudo (cf. l'en-tête de
    # scripts/secrets.sh). Le nix du système : c'est lui qui écrit le lock.
    DOTS_NIX = "${config.nix.package}/bin/nix";
    # `--clean` en plus du chemin du store, et ce n'est pas de la ceinture et
    # des bretelles : sans lui nvim lit $XDG_CONFIG_HOME/nvim/init.lua et
    # charge tout $XDG_DATA_HOME/nvim/site/pack/*/start. Ces chemins-là sont
    # des liens symboliques qui T'APPARTIENNENT — donc remplaçables par un
    # fichier ordinaire, donc exécutables en root. Le runtime de nvim reste
    # chargé, la coloration YAML avec.
    #
    # CE QU'ON PERD : le thème stylix et le LSP pendant l'édition d'un secret.
    # Un YAML de treize kilo-octets s'édite très bien sans. C'est le prix de la
    # frontière posée par modules/system/sops, qui ne vaut rien si cette
    # commande-là la reperce.
    DOTS_EDITOR = "${pkgs-stable.neovim}/bin/nvim --clean";
    # Première ligne du bloc généré du .sops.yaml (lib/sops-policy.nix).
    DOTS_SOPS_MARKER = myLib.sopsPolicy.marker;
  }
  # Palette des menus et messages (cf. scripts/lib/ui.sh) ; sans Stylix, les
  # couleurs du terminal, défaut de ui.sh.
  // lib.optionalAttrs config.stylix.enable (
    lib.mapAttrs' (role: v: lib.nameValuePair "DOTS_COLOR_${lib.toUpper role}" v) palette
  )
  # `theme` : galerie et navigateur épinglés dans le store.
  // lib.optionalAttrs stylix.enable {
    DOTS_GALLERY = (themes.galleryFor stylix.pkgs).server;
    DOTS_BROWSER = "${stylix.pkgs.firefox}/bin/firefox";
  };
in
{
  environment.systemPackages = [
    (pkgs-stable.callPackage myLib.commandsPackage {
      inherit settings;
      commands = [
        "rebuild"
        "update"
        "genclean"
        "secrets"
        "dots"
      ]
      ++ lib.optional stylix.enable "theme";
    })
  ];
}
