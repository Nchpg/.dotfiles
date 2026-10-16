# stylix.colors n'est évaluable que si stylix est actif pour ce user.
{ config, themes }:
let
  scheme = themes.parseScheme config.userSettings.stylix.theme;
  slots = builtins.filter (n: builtins.match "base[0-9A-F]{2}" n != null) (builtins.attrNames scheme);
  pick =
    f:
    builtins.listToAttrs (
      map (n: {
        name = n;
        value = f scheme.${n};
      }) slots
    );
in
pick (x: x) // { withHashtag = pick (x: "#${x}"); }
