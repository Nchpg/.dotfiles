# Les deux home.file partagés par tous les TUIs "en terminal flottant" de
# sway : un script lanceur (~/.config/sway/launchers/<name>, appelé par le
# bind ET un éventuel clic waybar) et son bind clavier + règle de fenêtre
# flottante (~/.config/sway/conf.d/<confName>.conf).
#
# La commande terminal est construite ici (mk-terminal-cmd.nix) avec le MÊME
# titre que celui matché par for_window : un seul paramètre, plus de
# désaccord possible entre les deux.
lib:
let
  mkTerminalCmd = import ./mk-terminal-cmd.nix lib;
in
{
  config,
  name, # nom du fichier launcher, ex. "bluetooth"
  confName ? name, # nom du fichier conf.d (souvent différent, ex. "bluetooth-picker")
  exec, # programme (+ arguments) lancé dans le terminal, chemin store de préférence
  env ? { }, # variables posées devant `exec` (ex. NEWT_COLORS)
  kittyExtraOpts ? "", # cf. mk-terminal-cmd.nix
  preamble ? "", # shell exécuté avant le lancement (ex. synchro), "" = aucun
  keybind, # ex. "$mod+b"
  # Titre EXACT matché par for_window (ancré ^…$). Sans ancrage c'est une
  # regex « contient », réévaluée à chaque changement de titre : un onglet
  # Firefox « … bluetui … » passait en flottant 1200x850.
  title,
  width,
  height,
}:
let
  termCmd = mkTerminalCmd {
    inherit
      config
      exec
      title
      kittyExtraOpts
      ;
  };
  envPrefix = lib.concatMapAttrsStringSep "" (n: v: "${n}=${lib.escapeShellArg v} ") env;
in
{
  home.file.".config/sway/launchers/${name}" = {
    text = ''
      #!/bin/sh
      ${preamble}${envPrefix}exec ${termCmd}
    '';
    executable = true;
  };

  home.file.".config/sway/conf.d/${confName}.conf".text = ''
    bindsym ${keybind} exec ~/.config/sway/launchers/${name}
    for_window [title="^${title}$"] floating enable, resize set ${toString width} ${toString height}, border pixel 2
  '';
}
