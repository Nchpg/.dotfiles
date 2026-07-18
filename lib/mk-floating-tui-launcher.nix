# Génère les deux home.file partagés par tous les TUIs "en terminal flottant"
# de sway : un script lanceur (~/.config/sway/launchers/<name>, appelé par le
# bind ET par un éventuel clic waybar) et son bind clavier + règle de fenêtre
# flottante (~/.config/sway/conf.d/<confName>.conf). Cf. bluetooth-picker,
# wifi-picker, volume-mixer, lg-control, systemd-manager-tui, task-tui,
# calendar-tui : même forme à chaque fois, seuls le nom, la commande, le bind,
# le titre de fenêtre matché et la taille changent.
{
  name, # nom du fichier launcher, ex. "bluetooth"
  confName ? name, # nom du fichier conf.d (souvent différent, ex. "bluetooth-picker")
  scriptBody, # corps du script après le shebang, doit se terminer par `exec ...`
  keybind, # ex. "$mod+b"
  title, # titre de fenêtre matché par for_window
  width,
  height,
}:
{
  home.file.".config/sway/launchers/${name}" = {
    text = ''
      #!/bin/sh
      ${scriptBody}
    '';
    executable = true;
  };

  home.file.".config/sway/conf.d/${confName}.conf".text = ''
    bindsym ${keybind} exec ~/.config/sway/launchers/${name}
    for_window [title="${title}"] floating enable, resize set ${toString width} ${toString height}, border pixel 2
  '';
}
