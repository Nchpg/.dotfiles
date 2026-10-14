# Icône de notification (notify-send -i) aux couleurs du thème, avec repli
# intégré : sans stylix pour ce user, `config.lib.stylix.colors` n'est pas
# évaluable, on rend alors le nom Adwaita (`battery-low-symbolic`), que
# swaync affiche en blanc. Cf. mk-themed-icon.nix pour la recoloration.
#
#   icon = myLib.notifyIcon config cfg.pkgs;
#   icon "status/battery-low" (c: c.base0A)
config: pkgs: name: pick:
if config.userSettings.stylix.enable then
  "${import ./mk-themed-icon.nix pkgs name (pick config.lib.stylix.colors.withHashtag)}"
else
  "${baseNameOf name}-symbolic"
