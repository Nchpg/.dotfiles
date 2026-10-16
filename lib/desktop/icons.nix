lib: rec {
  # Le glyphe tapé en dur se ferait stripper.
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

  mkThemedIcon =
    pkgs: name: color:
    pkgs.runCommand "${baseNameOf name}-${builtins.substring 1 6 color}.svg" { } ''
      sed -E 's/fill="#[0-9a-fA-F]{6}"/fill="${color}"/g' \
        ${pkgs.adwaita-icon-theme}/share/icons/Adwaita/symbolic/${name}-symbolic.svg > $out
    '';

  notifyIcon =
    config: pkgs: name: pick:
    if config.userSettings.stylix.enable then
      "${mkThemedIcon pkgs name (pick config.lib.stylix.colors.withHashtag)}"
    else
      "${baseNameOf name}-symbolic";
}
