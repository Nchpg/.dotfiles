# Entrée rofi (drun) d'une action système : un .desktop et son icône SVG.
# Adwaita ne fournit que des -symbolic en #2e3436, invisibles sur le fond
# foncé de rofi : glyphe maison d'un seul tracé, coloré au thème.
#
#   myLib.desktop.mkRofiAction {
#     inherit config;
#     name = "shutdown"; label = "Shutdown"; comment = "…";
#     exec = "systemctl poweroff"; color = c.base05; path = "M12 3 v9 …";
#   }
#   => { xdg.dataFile."icons/rofi-shutdown.svg" ; xdg.dataFile."applications/shutdown.desktop" }
{
  config,
  name, # nom du .desktop et de l'icône
  label, # Name= affiché par rofi
  comment,
  exec,
  color, # trait du glyphe, ex. c.base05
  path, # attribut `d` du <path> SVG (viewBox 24x24)
}:
{
  xdg.dataFile."icons/rofi-${name}.svg".text = ''
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24">
      <path fill="none" stroke="${color}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
            d="${path}"/>
    </svg>
  '';

  xdg.dataFile."applications/${name}.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=${label}
    Comment=${comment}
    Icon=${config.xdg.dataHome}/icons/rofi-${name}.svg
    Exec=${exec}
    Terminal=false
  '';
}
