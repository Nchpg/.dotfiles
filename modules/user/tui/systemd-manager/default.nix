{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.tui.systemdManager;

  # En amont, seul Ctrl+C quitte l'app (touches en dur). Patché pour quitter
  # aussi avec q/Esc, mais UNIQUEMENT sur l'écran liste hors édition du
  # filtre (sinon casse la frappe de "q" dans la recherche, et le retour
  # arrière q/Esc des écrans Détails/Log qui reviennent déjà à la liste).
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
in
{
  options.userSettings.tui.systemdManager = {
    enable = lib.mkEnableOption "systemd-manager-tui (gestion des services systemd dans un terminal flottant)";
    pkgs = myLib.mkPkgsOption { inherit lib config; };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (myLib.mkFloatingTuiLauncher {
        name = "systemd-manager";
        confName = "systemd-manager-tui";
        inherit config;
        exec = "${systemd-manager-tui}/bin/systemd-manager-tui";
        keybind = "$mod+m";
        title = "systemd-manager-tui";
        width = 1200;
        height = 850;
      })
      { home.packages = [ systemd-manager-tui ]; }
    ]
  );
}
