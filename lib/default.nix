# Agrégateur des helpers du dépôt, injecté sous le nom `myLib` dans TOUS les
# modules (specialArgs système + extraSpecialArgs home-manager, cf. flake.nix)
# et consommé aussi par flake.nix lui-même.
#
# Raison d'être : les modules appelaient ces helpers par chemin relatif
# (`import ../../../../lib/mk-pkgs-option.nix`), donc la profondeur du dossier
# faisait partie du code — déplacer un module cassait ses imports, et une
# erreur de comptage de `../` ne se voyait qu'à l'éval. Passer par un argument
# rend les modules insensibles à leur position dans l'arborescence.
#
# Rangé par domaine, un sous-dossier = un attribut de myLib (myLib.sops.policy,
# myLib.server.mkProbe…) ; seule la mécanique des modules, appelée partout,
# reste à la racine. Les helpers qui ont besoin de `lib` le reçoivent ici une
# fois pour toutes ; les autres prennent leurs arguments à l'appel.
lib:

{
  # ── Mécanique des modules (lib/modules) ─────────────────────────────────────
  inherit (import ./modules/discover.nix lib) dirNames nixFileNames;
  importAll = import ./modules/import-all.nix lib;
  optionEnabled = import ./modules/option-enabled.nix lib;
  mkPkgsOption = import ./modules/pkgs-option.nix;
  mkPackageModule = import ./modules/package-module.nix;
  deepMergeJsonActivation = import ./modules/deep-merge-json-activation.nix;

  # Le paquet des commandes du dépôt, à passer à callPackage (cf.
  # scripts/default.nix).
  commandsPackage = ../scripts;

  # ── Ce que seul flake.nix utilise (lib/flake) ───────────────────────────────
  flake = {
    targetName = import ./flake/target-name.nix lib;
    contentHash = import ./flake/content-hash.nix lib;
    mkEvalCheck = import ./flake/eval-check.nix lib;
    checkOptionPaths = import ./flake/check-option-paths.nix lib;
  };

  # ── Secrets sops (lib/sops) ─────────────────────────────────────────────────
  sops = {
    policy = import ./sops/policy.nix lib;
    audience = import ./sops/audience.nix lib;
    checkPolicy = import ./sops/check-policy.nix lib;
    assertAvailable = import ./sops/assert-available.nix;
    mkSecretEnvWrapper = import ./sops/secret-env-wrapper.nix lib;
  };

  # ── Services du serveur, nginx (lib/server) ─────────────────────────────────
  server = {
    mkTlsVhost = import ./server/tls-vhost.nix;
    mkInternalPorts = import ./server/internal-ports.nix lib;
    mkProbe = import ./server/probe.nix lib;
    mkErrorPage = import ./server/error-page.nix;
    nginxAllowOnly = import ./server/nginx-allow-only.nix lib;
    nonRoutableIPv4 = import ./server/non-routable-ipv4.nix;
    mkNextcloudShareLinkPatch = import ./server/nextcloud-share-link-patch.nix;
    grafana = import ./server/grafana.nix lib;
  };

  # ── Bureau : sway, terminal, TUI (lib/desktop) ──────────────────────────────
  desktop = {
    mkTerminalCmd = import ./desktop/terminal-cmd.nix lib;
    inherit (import ./desktop/terminal-shell.nix) mkTerminalShellBin mkTerminalShellOption;
    mkFloatingTuiLauncher = import ./desktop/floating-tui-launcher.nix lib;
    mkWaybarMenu = import ./desktop/waybar-menu.nix lib;
    mkRofiAction = import ./desktop/rofi-action.nix;
    inherit (import ./desktop/icons.nix lib) mkIcon mkThemedIcon notifyIcon;
    # Fonctions bash d'attente d'une fenêtre sway (sway_wait…), à inliner en
    # tête d'un script writeShellApplication.
    swayWaitSh = builtins.readFile ./desktop/sway-wait.sh;
  };

  # ── Couleurs du thème (lib/theme) ───────────────────────────────────────────
  theme = {
    schemeColors = import ./theme/scheme-colors.nix;
    uiPalette = import ./theme/ui-palette.nix;
    mkGumEnv = import ./theme/gum-env.nix;
  };

  # ── Construction de paquets (lib/packaging) ─────────────────────────────────
  packaging = {
    fetchPinned = import ./packaging/fetch-pinned.nix lib;
    mkGuardedPatch = import ./packaging/guarded-patch.nix lib;
    editorLspPackages = import ./packaging/editor-lsp-packages.nix;
  };
}
