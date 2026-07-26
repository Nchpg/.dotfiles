# Lit `userSettings.<path>.enable` depuis un chemin donné EN CHAÎNE, et
# ÉCHOUE si le chemin n'existe pas.
#
# Raison d'être : sway/default.nix (`bindIf`) et waybar/default.nix
# (`clickIf`) décident d'émettre un bind clavier ou un `on-click` selon qu'un
# autre module est activé. Ces chemins sont des chaînes, donc invisibles pour
# tout ce qui vérifie du Nix — ni l'évaluation, ni deadnix, ni le check
# option-paths ne les regardent.
#
# La version précédente faisait `attrByPath … false` : un chemin périmé
# renvoyait `false`, donc « module désactivé », donc PAS de bind et PAS de
# on-click — sans le moindre message. C'est arrivé pour de vrai : le
# déplacement des pickers sous windowManager.sway a laissé
# `clickIf "pickers.wifi"` et `clickIf "pickers.bluetooth"` derrière lui, et
# les clics wifi/bluetooth de la barre sont restés morts, la config
# continuant à évaluer et à construire sans broncher.
#
# Un chemin faux est désormais une erreur d'évaluation. Le défaut de mise à
# jour reste possible, mais il ne peut plus être silencieux.
lib:

userSettings: path:
let
  parts = lib.splitString "." path ++ [ "enable" ];
in
if lib.hasAttrByPath parts userSettings then
  lib.getAttrFromPath parts userSettings
else
  throw "option-enabled : le chemin « userSettings.${path}.enable » n'existe pas (module déplacé ou renommé ?). Corrige la chaîne à l'appelant."
