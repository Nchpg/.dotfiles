{ config, lib, ... }:

let
  cfg = config.userSettings.systemdManagerTui;
  term = config.userSettings.terminal.default;

  # systemd-manager-tui (ratatui) utilise la palette du terminal : il hérite
  # donc automatiquement du thème Stylix via le terminal (kitty), comme bluetui
  # pour le bluetooth-picker. Aucun fichier de thème à générer.
  #
  # En amont, seul Ctrl+C quitte l'app (touches en dur, aucun fichier de config).
  # On patche la source pour quitter AUSSI avec `q`/`Esc`, mais UNIQUEMENT sur
  # l'écran liste et hors édition du filtre — sinon on casserait la frappe de
  # « q » dans la recherche et le retour arrière `q`/`Esc` depuis les écrans
  # Détails/Log (qui, eux, reviennent déjà à la liste). On ancre sur la signature
  # (unique) de on_key_event et on injecte le test juste après l'accolade.
  systemd-manager-tui = cfg.pkgs.systemd-manager-tui.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/terminal/app.rs \
        --replace-fail \
        "fn on_key_event(&mut self, key: KeyEvent, terminal: &mut DefaultTerminal) -> Result<()> {" \
        "fn on_key_event(&mut self, key: KeyEvent, terminal: &mut DefaultTerminal) -> Result<()> {
            if self.status == Status::List
                && self.filter.input_mode == InputMode::Normal
                && matches!(key.code, KeyCode::Esc | KeyCode::Char('q' | 'Q'))
            {
                self.quit();
            }"
    '';
  });

  termCmd =
    if term == "alacritty"
    then "${term} --title systemd-manager-tui -e ${systemd-manager-tui}/bin/systemd-manager-tui"
    else "${term} --title systemd-manager-tui ${systemd-manager-tui}/bin/systemd-manager-tui";
in {
  options.userSettings.systemdManagerTui = {
    enable = lib.mkEnableOption "systemd-manager-tui (gestion des services systemd dans un terminal flottant)";
    pkgs = lib.mkOption {
      type = lib.types.pkgs;
      default = config.userSettings.defaultPkgs;
      description = "Pkgs to use";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ systemd-manager-tui ];

    # Launcher partagé entre le bind sway et un éventuel clic swaybar (DRY),
    # comme les autres pickers/TUIs.
    home.file.".config/sway/launchers/systemd-manager" = {
      text = ''
        #!/bin/sh
        exec ${termCmd}
      '';
      executable = true;
    };

    home.file.".config/sway/conf.d/systemd-manager-tui.conf".text = ''
      bindsym $mod+m exec ~/.config/sway/launchers/systemd-manager
      for_window [title="systemd-manager-tui"] floating enable, resize set 1200 850, border pixel 2
    '';
  };
}
