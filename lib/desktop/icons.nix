# Icônes : glyphes de police (waybar…) et icônes de notification aux couleurs
# du thème. Exposé sous myLib.desktop.
lib: rec {
  # Codepoint hexa -> glyphe, BMP ou plan astral (icônes Material Design >
  # U+FFFF -> paire de substitution UTF-16). Évite de taper le glyphe en dur
  # dans les sources (il se ferait stripper au copier-coller / au formatage).
  #
  #   myLib.desktop.mkIcon "f009a"
  mkIcon =
    hex:
    let
      digits = {
        "0" = 0;
        "1" = 1;
        "2" = 2;
        "3" = 3;
        "4" = 4;
        "5" = 5;
        "6" = 6;
        "7" = 7;
        "8" = 8;
        "9" = 9;
        "a" = 10;
        "b" = 11;
        "c" = 12;
        "d" = 13;
        "e" = 14;
        "f" = 15;
      };
      toInt = s: lib.foldl (acc: ch: acc * 16 + digits.${lib.toLower ch}) 0 (lib.stringToCharacters s);
      toHex4 = x: lib.toLower (lib.fixedWidthString 4 "0" (lib.toHexString x));
      n = toInt hex;
    in
    if n <= 65535 then
      builtins.fromJSON ''"\u${toHex4 n}"''
    else
      let
        v = n - 65536;
        hi = 55296 + (v / 1024);
        lo = 56320 + (v - (v / 1024) * 1024);
      in
      builtins.fromJSON ''"\u${toHex4 hi}\u${toHex4 lo}"'';

  # Icône « symbolic » Adwaita recolorée (SVG dans le store), pour notify-send.
  # swaync affiche le SVG tel quel, sans recoloration CSS possible : le gris
  # foncé d'origine (#222222 / #2e3436) se perdait sur le fond des notifs.
  # Ces icônes n'ont que des remplissages en couleur fixe, tous remplacés.
  #
  #   myLib.desktop.mkThemedIcon pkgs "status/battery-low" c.base0A
  mkThemedIcon =
    pkgs: name: color:
    pkgs.runCommand "${baseNameOf name}-${builtins.substring 1 6 color}.svg" { } ''
      sed -E 's/fill="#[0-9a-fA-F]{6}"/fill="${color}"/g' \
        ${pkgs.adwaita-icon-theme}/share/icons/Adwaita/symbolic/${name}-symbolic.svg > $out
    '';

  # Icône de notification (notify-send -i) aux couleurs du thème, avec repli
  # intégré : sans stylix pour ce user, `config.lib.stylix.colors` n'est pas
  # évaluable, on rend alors le nom Adwaita (`battery-low-symbolic`), que
  # swaync affiche en blanc.
  #
  #   icon = myLib.desktop.notifyIcon config cfg.pkgs;
  #   icon "status/battery-low" (c: c.base0A)
  notifyIcon =
    config: pkgs: name: pick:
    if config.userSettings.stylix.enable then
      "${mkThemedIcon pkgs name (pick config.lib.stylix.colors.withHashtag)}"
    else
      "${baseNameOf name}-symbolic";
}
