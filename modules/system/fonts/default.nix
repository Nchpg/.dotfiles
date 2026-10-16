{
  pkgs-stable,
  themes,
  ...
}:

{
  fonts.packages = (themes.fontsFor pkgs-stable).packages;
}
