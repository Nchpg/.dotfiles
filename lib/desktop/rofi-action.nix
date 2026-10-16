{
  config,
  name,
  label,
  comment,
  exec,
  color,
  path,
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
