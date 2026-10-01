# Les deux home.file partagés par tous les TUIs "en terminal flottant" de
# sway : un script lanceur (~/.config/sway/launchers/<name>, appelé par le
# bind ET un éventuel clic waybar) et son bind clavier + règle de fenêtre
# flottante (~/.config/sway/conf.d/<confName>.conf).
{
  name, # nom du fichier launcher, ex. "bluetooth"
  confName ? name, # nom du fichier conf.d (souvent différent, ex. "bluetooth-picker")
  scriptBody, # corps du script après le shebang, doit se terminer par `exec ...`
  keybind, # ex. "$mod+b"
  # Titre EXACT matché par for_window (ancré ^…$). Sans ancrage c'est une
  # regex « contient », réévaluée à chaque changement de titre : un onglet
  # Firefox « … bluetui … » passait en flottant 1200x850.
  title,
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
    for_window [title="^${title}$"] floating enable, resize set ${toString width} ${toString height}, border pixel 2
  '';
}
