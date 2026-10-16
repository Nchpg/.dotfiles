# colors = null (serveur sans Stylix) : numéros de couleur du terminal.
colors:
if colors != null then
  {
    accent = "#${colors.base0D}";
    ok = "#${colors.base0B}";
    warn = "#${colors.base0A}";
    err = "#${colors.base08}";
    dim = "#${colors.base03}";
    text = "#${colors.base05}";
    base = "#${colors.base00}";
  }
else
  {
    accent = "4";
    ok = "2";
    warn = "3";
    err = "1";
    dim = "8";
    text = "7";
    base = "0";
  }
