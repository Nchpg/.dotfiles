# Menu clic droit d'un module waybar : le XML GtkBuilder (menu-file) ET les
# menu-actions, tirés d'une seule liste. Les ids GTK n'étaient sinon écrits
# qu'à la main des deux côtés, et un id renommé d'un seul côté donnait une
# entrée muette, sans erreur.
#
#   myLib.desktop.mkWaybarMenu [
#     { id = "mute"; label = "Mute / Unmute"; action = volMute; }
#     "sep"
#     { id = "mixer"; label = "Ouvrir le mixer"; action = null; } # entrée sans action
#   ]
#   => { xml = "<?xml …"; actions = { mute = volMute; }; }
#
# Un id ne doit pas commencer par un chiffre (GtkBuilder) : préfixer (pct25).
lib: items:
let
  # Libellés et ids saisis librement (villes météo) : échappement XML minimal.
  escapeXml = lib.replaceStrings [ "&" "<" ">" "\"" "'" ] [ "&amp;" "&lt;" "&gt;" "&quot;" "&apos;" ];

  # Séparateurs numérotés dans l'ordre (sep1, sep2…) : GtkBuilder exige des
  # ids uniques, personne ne les référence.
  # Lignes indentées à la main : une chaîne multi-ligne interpolée dans un
  # bloc indenté n'est pas réindentée.
  child = lines: lib.concatMapStrings (l: "    ${l}\n") ([ "<child>" ] ++ lines ++ [ "</child>" ]);
  render =
    acc: item:
    if item == "sep" then
      {
        n = acc.n + 1;
        xml =
          acc.xml
          + child [
            "  <object class=\"GtkSeparatorMenuItem\" id=\"sep${toString (acc.n + 1)}\"/>"
          ];
      }
    else
      acc
      // {
        xml =
          acc.xml
          + child [
            "  <object class=\"GtkMenuItem\" id=\"${escapeXml item.id}\">"
            "    <property name=\"label\">${escapeXml item.label}</property>"
            "  </object>"
          ];
      };

  entries = lib.filter (i: i != "sep" && (i.action or null) != null) items;
in
{
  xml = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <interface>
      <object class="GtkMenu" id="menu">
  ''
  + (lib.foldl' render {
    n = 0;
    xml = "";
  } items).xml
  + ''
      </object>
    </interface>
  '';

  actions = lib.listToAttrs (map (i: lib.nameValuePair i.id i.action) entries);
}
