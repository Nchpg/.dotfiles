{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.browsers.firefox;
  # Même source que rofi/waybar. CSS émis seulement si stylix est activé
  # (sinon `colors` n'est pas évaluable).
  c = config.lib.stylix.colors;
  themed = config.userSettings.stylix.enable;
in
{
  options = {
    userSettings.browsers.firefox = {
      enable = lib.mkEnableOption "Enable firefox browser";
      pkgs = myLib.mkPkgsOption { inherit lib config; };
    };
  };
  config = lib.mkIf cfg.enable {
    programs.firefox = {
      enable = true;
      package = cfg.pkgs.firefox;
      # Accordées d'office (policy entreprise), sans bannière. Rend déclaratif
      # ce qui vit normalement dans permissions.sqlite (non reproductible).
      policies.Permissions.Notifications = {
        Allow = [
          "https://discord.com"
          "https://claude.ai"
        ];
        BlockNewRequests = false; # autres sites toujours libres de demander
      };
      # 26.05 a changé le défaut vers $XDG_CONFIG_HOME/mozilla/firefox : on
      # garde le chemin historique pour ne pas déplacer ~/.mozilla.
      configPath = ".mozilla/firefox";
      profiles.default = {
        # Pas de extensions.packages -> pas de extensions.force (sinon
        # désinstalle au rebuild toute extension installée à la main).
        settings = {
          "toolkit.legacyUserProfileCustomizations.stylesheets" = true;
          # Rouvre fenêtres et onglets de la dernière fois : c'est ce qui
          # remplit les fenêtres que `sway-session restore` remet en place.
          "browser.startup.page" = 3;
        };
        userChrome = lib.optionalString themed ''
          /* Appliquer uniquement les couleurs Stylix sans modifier la disposition */
          :root {
            --toolbar-bgcolor: #${c.base00} !important;
            --toolbar-color: #${c.base05} !important;
            --toolbar-field-background-color: #${c.base00} !important;
            --toolbar-field-color: #${c.base05} !important;
            --toolbar-field-border-color: #${c.base03} !important;
            --lwt-accent-color: #${c.base00} !important;
            --lwt-accent-color-inactive: #${c.base00} !important;
            --lwt-text-color: #${c.base05} !important;
            --lwt-selected-tab-background-color: #${c.base02} !important;
            --tab-selected-bgcolor: #${c.base02} !important;
            --arrowpanel-background: #${c.base00} !important;
            --arrowpanel-color: #${c.base05} !important;
          }

          /* Barre d'outils principale */
          #nav-bar {
            background-color: #${c.base00} !important;
          }

          #navigator-toolbox {
            background-color: var(--toolbar-bgcolor) !important;
          }

          /* Barre d'adresse et champs de recherche */
          #urlbar, .searchbar-textbox {
            background-color: #${c.base00} !important;
            color: #${c.base05} !important;
            border-color: #${c.base03} !important;
          }

          #urlbar-background {
            background-color: #${c.base00} !important;
          }

          /* Menu déroulants */
          menupopup, panel, .panel-arrowcontent {
            background-color: #${c.base00} !important;
            color: #${c.base05} !important;
            border-color: #${c.base03} !important;
          }

          menuitem:hover, menu:hover {
            background-color: #${c.base02} !important;
          }

          /* Onglets sélectionnés */
          .tabbrowser-tab[selected] .tab-background {
            background-color: #${c.base02} !important;
          }

          .tabbrowser-tab:is([selected], [visuallyselected="true"]) .tab-background {
            background-color: #${c.base02} !important;
          }

          .tabbrowser-tab[selected] .tab-label {
            color: #${c.base05} !important;
          }

          /* Onglets non sélectionnés */
          .tabbrowser-tab:not([selected]) .tab-background {
            background-color: #${c.base00} !important;
          }

          .tabbrowser-tab:not([selected], [visuallyselected="true"]) .tab-background {
            background-color: #${c.base00} !important;
          }

          .tabbrowser-tab:not([selected]) .tab-label {
            color: #${c.base04} !important;
          }

          /* Hover sur les onglets */
          .tabbrowser-tab:hover:not([selected]) .tab-background {
            background-color: #${c.base00} !important;
          }

          /* Sidebar */
          #sidebar-box, #sidebar-header {
            background-color: #${c.base00} !important;
            color: #${c.base05} !important;
          }
        '';

        userContent = lib.optionalString themed ''
          /* Personnalisation des pages internes de Firefox */
          @-moz-document url-prefix(about:), url-prefix(chrome://) {
            :root {
              --in-content-page-background: #${c.base00} !important;
              --in-content-page-color: #${c.base05} !important;
              --in-content-box-background: #${c.base00} !important;
              --in-content-box-background-odd: #${c.base00} !important;
              --in-content-border-color: #${c.base03} !important;
              --in-content-button-background: #${c.base02} !important;
              --in-content-button-background-hover: #${c.base03} !important;
              --in-content-primary-button-background: #${c.base0D} !important;
              --in-content-primary-button-background-hover: #${c.base0E} !important;
            }
          }
        '';
      };
    };

    stylix.targets.firefox = {
      enable = themed;
      profileNames = [ "default" ];
    };

    home.file.".config/sway/conf.d/firefox.conf" =
      lib.mkIf config.userSettings.windowManager.sway.enable
        {
          text = ''
            bindsym $mod+Shift+f exec firefox
          '';
        };
  };
}
