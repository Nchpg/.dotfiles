# Icône « symbolic » Adwaita recolorée (SVG dans le store), pour notify-send.
# swaync affiche le SVG tel quel, sans recoloration CSS possible : le gris
# foncé d'origine (#222222 / #2e3436) se perdait sur le fond des notifs.
# Ces icônes n'ont que des remplissages en couleur fixe, tous remplacés.
#
# Usage : myLib.mkThemedIcon pkgs "status/battery-low" c.base0A
pkgs: name: color:
pkgs.runCommand "${baseNameOf name}-${builtins.substring 1 6 color}.svg" { } ''
  sed -E 's/fill="#[0-9a-fA-F]{6}"/fill="${color}"/g' \
    ${pkgs.adwaita-icon-theme}/share/icons/Adwaita/symbolic/${name}-symbolic.svg > $out
''
