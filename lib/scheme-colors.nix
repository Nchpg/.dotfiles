# Couleurs du scheme actif du user, même forme que `config.lib.stylix.colors`
# (hex sans '#', plus `.withHashtag` avec), mais lues via themes.parseScheme.
#
# Pourquoi pas `config.lib.stylix.colors` directement : il n'est évaluable
# que si stylix est actif pour ce user, alors que `userSettings.stylix.theme`
# a TOUJOURS une valeur (défaut = thème système). Avec stylix actif, les deux
# donnent les mêmes valeurs : stylix reçoit justement ce parseScheme en
# base16Scheme (cf. themes.stylixSettings).
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
