{
  lib,
  config,
  pkgs-stable,
  target,
  myLib,
  themes,
  ...
}:

let
  stylix = config.systemSettings.stylix;

  palette = myLib.theme.uiPalette (if config.stylix.enable then config.lib.stylix.colors else null);

  settings = {
    DOTS_PROFILE = target.profile;
    DOTS_HOST = target.host;
    DOTS_VARIANT = target.variant;

    DOTS_NIX = "${config.nix.package}/bin/nix";
    # `--clean` : nvim chargerait config et plugins de $XDG_* (liens d'user, exécutés en root).
    DOTS_EDITOR = "${pkgs-stable.neovim}/bin/nvim --clean";
    DOTS_SOPS_MARKER = myLib.sops.policy.marker;
  }
  // lib.optionalAttrs config.stylix.enable (
    lib.mapAttrs' (role: v: lib.nameValuePair "DOTS_COLOR_${lib.toUpper role}" v) palette
  )
  // lib.optionalAttrs stylix.enable {
    DOTS_GALLERY = (themes.galleryFor stylix.pkgs).server;
    DOTS_BROWSER = "${stylix.pkgs.firefox}/bin/firefox";
  };
in
{
  environment.systemPackages = [
    (pkgs-stable.callPackage ../../../scripts {
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
