{ config, lib, pkgs-stable, pkgs-unstable, stylix, ... }:

let
  cfg = config.userSettings.firefox;
in {
  options = {
    userSettings.firefox = {
      enable = lib.mkEnableOption "Enable firefox browser";
      pkgs = lib.mkOption {
        type = lib.types.attrs;
        default = config.userSettings.defaultPkgs;
        description = "Pkgs to use";
      };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.firefox = {
      enable = true;
      package = cfg.pkgs.firefox;
      profiles.default = {
        extensions.force = lib.mkForce true;
        settings = {
          "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
        };
        userChrome = ''
          /* Appliquer uniquement les couleurs Stylix sans modifier la disposition */
          :root {
            --toolbar-bgcolor: #${config.userSettings.stylix.themeconfig.base00} !important;
            --toolbar-color: #${config.userSettings.stylix.themeconfig.base05} !important;
            --toolbar-field-background-color: #${config.userSettings.stylix.themeconfig.base00} !important;
            --toolbar-field-color: #${config.userSettings.stylix.themeconfig.base05} !important;
            --toolbar-field-border-color: #${config.userSettings.stylix.themeconfig.base03} !important;
            --lwt-accent-color: #${config.userSettings.stylix.themeconfig.base00} !important;
            --lwt-accent-color-inactive: #${config.userSettings.stylix.themeconfig.base00} !important;
            --lwt-text-color: #${config.userSettings.stylix.themeconfig.base05} !important;
            --lwt-selected-tab-background-color: #${config.userSettings.stylix.themeconfig.base02} !important;
            --tab-selected-bgcolor: #${config.userSettings.stylix.themeconfig.base02} !important;
            --arrowpanel-background: #${config.userSettings.stylix.themeconfig.base00} !important;
            --arrowpanel-color: #${config.userSettings.stylix.themeconfig.base05} !important;
          }

          /* Barre d'outils principale */
          #nav-bar {
            background-color: #${config.userSettings.stylix.themeconfig.base00} !important;
          }

          #navigator-toolbox {
            background-color: var(--toolbar-bgcolor) !important;
          }

          /* Barre d'adresse et champs de recherche */
          #urlbar, .searchbar-textbox {
            background-color: #${config.userSettings.stylix.themeconfig.base00} !important;
            color: #${config.userSettings.stylix.themeconfig.base05} !important;
            border-color: #${config.userSettings.stylix.themeconfig.base03} !important;
          }

          #urlbar-background {
            background-color: #${config.userSettings.stylix.themeconfig.base00} !important;
          }

          /* Menu déroulants */
          menupopup, panel, .panel-arrowcontent {
            background-color: #${config.userSettings.stylix.themeconfig.base00} !important;
            color: #${config.userSettings.stylix.themeconfig.base05} !important;
            border-color: #${config.userSettings.stylix.themeconfig.base03} !important;
          }

          menuitem:hover, menu:hover {
            background-color: #${config.userSettings.stylix.themeconfig.base02} !important;
          }

          /* Onglets sélectionnés */
          .tabbrowser-tab[selected] .tab-background {
            background-color: #${config.userSettings.stylix.themeconfig.base02} !important;
          }

          .tabbrowser-tab:is([selected], [visuallyselected="true"]) .tab-background {
            background-color: #${config.userSettings.stylix.themeconfig.base02} !important;
          }

          .tabbrowser-tab[selected] .tab-label {
            color: #${config.userSettings.stylix.themeconfig.base05} !important;
          }

          /* Onglets non sélectionnés */
          .tabbrowser-tab:not([selected]) .tab-background {
            background-color: #${config.userSettings.stylix.themeconfig.base00} !important;
          }

          .tabbrowser-tab:not([selected], [visuallyselected="true"]) .tab-background {
            background-color: #${config.userSettings.stylix.themeconfig.base00} !important;
          }

          .tabbrowser-tab:not([selected]) .tab-label {
            color: #${config.userSettings.stylix.themeconfig.base04} !important;
          }

          /* Hover sur les onglets */
          .tabbrowser-tab:hover:not([selected]) .tab-background {
            background-color: #${config.userSettings.stylix.themeconfig.base00} !important;
          }

          /* Sidebar */
          #sidebar-box, #sidebar-header {
            background-color: #${config.userSettings.stylix.themeconfig.base00} !important;
            color: #${config.userSettings.stylix.themeconfig.base05} !important;
          }
        '';

        userContent = ''
          /* Personnalisation des pages internes de Firefox */
          @-moz-document url-prefix(about:), url-prefix(chrome://) {
            :root {
              --in-content-page-background: #${config.userSettings.stylix.themeconfig.base00} !important;
              --in-content-page-color: #${config.userSettings.stylix.themeconfig.base05} !important;
              --in-content-box-background: #${config.userSettings.stylix.themeconfig.base00} !important;
              --in-content-box-background-odd: #${config.userSettings.stylix.themeconfig.base00} !important;
              --in-content-border-color: #${config.userSettings.stylix.themeconfig.base03} !important;
              --in-content-button-background: #${config.userSettings.stylix.themeconfig.base02} !important;
              --in-content-button-background-hover: #${config.userSettings.stylix.themeconfig.base03} !important;
              --in-content-primary-button-background: #${config.userSettings.stylix.themeconfig.base0D} !important;
              --in-content-primary-button-background-hover: #${config.userSettings.stylix.themeconfig.base0E} !important;
            }
        '';
      };
    };

    stylix.targets.firefox = {
      enable = true;
      profileNames = [ "default" ]; 
    };
  };
}