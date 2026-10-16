lib:

{
  importAll = import ./modules/import-all.nix lib;
  mkPkgsOption = import ./modules/pkgs-option.nix;
  mkPackageModule = import ./modules/package-module.nix;
  deepMergeJsonActivation = import ./modules/deep-merge-json-activation.nix;

  flake = {
    targetName = import ./flake/target-name.nix lib;
    checkOptionPaths = import ./flake/check-option-paths.nix lib;
  };

  sops = {
    policy = import ./sops/policy.nix lib;
    audience = import ./sops/audience.nix lib;
    checkPolicy = import ./sops/check-policy.nix lib;
    assertAvailable = import ./sops/assert-available.nix;
    mkSecretEnvWrapper = import ./sops/secret-env-wrapper.nix lib;
  };

  server = {
    mkTlsVhost = import ./server/tls-vhost.nix;
    mkInternalPorts = import ./server/internal-ports.nix lib;
    mkProbe = import ./server/probe.nix lib;
    mkErrorPage = import ./server/error-page.nix;
    nginxAllowOnly = import ./server/nginx-allow-only.nix lib;
    nonRoutableIPv4 = import ./server/non-routable-ipv4.nix;
    grafana = import ./server/grafana.nix lib;
  };

  desktop = {
    mkTerminalCmd = import ./desktop/terminal-cmd.nix lib;
    inherit (import ./desktop/terminal-shell.nix) mkTerminalShellBin mkTerminalShellOption;
    mkFloatingTuiLauncher = import ./desktop/floating-tui-launcher.nix lib;
    mkWaybarMenu = import ./desktop/waybar-menu.nix lib;
    mkRofiAction = import ./desktop/rofi-action.nix;
    inherit (import ./desktop/icons.nix lib) mkIcon notifyIcon;
    swayWaitSh = builtins.readFile ./desktop/sway-wait.sh;
  };

  theme = {
    schemeColors = import ./theme/scheme-colors.nix;
    uiPalette = import ./theme/ui-palette.nix;
    mkGumEnv = import ./theme/gum-env.nix;
  };

  packaging = {
    fetchPinned = import ./packaging/fetch-pinned.nix lib;
    mkGuardedPatch = import ./packaging/guarded-patch.nix lib;
    editorLspPackages = import ./packaging/editor-lsp-packages.nix;
  };
}
