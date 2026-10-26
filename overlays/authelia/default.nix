# Authelia avec un thème visuel maison : uniquement du CSS, appliqué au build du frontend.
#
# Le paquet vient d'unstable : le thème vise le frontend Tailwind, absent de la
# version de nixos-26.05.
#
# Un bump touchant ces CSS fait échouer le build : rebaser ou retirer le patch.
# Un bump touchant le markup du frontend ne casse rien mais peut dégrader le
# rendu : revérifier les pages après chaque mise à jour de nixpkgs-unstable.
{ myLib, pkgs-unstable }:
_final: _prev:
let
  web = myLib.packaging.mkGuardedPatch {
    package = pkgs-unstable.callPackage "${pkgs-unstable.path}/pkgs/by-name/au/authelia/web.nix" { };
    patch = ./theme.patch;
    files = {
      "src/index.css" = "0034adb5e86778607668d57258835f84d4b206185c3099630981c7950fa5e0c8";
      "src/themes/tailwind-themes.css" =
        "6dc146de415e599cc428db5478a263aec013295604fc8086a35c12f97a34b3d3";
    };
    where = "overlays/authelia/default.nix";
  };
in
{
  authelia = pkgs-unstable.authelia.override { authelia-web = web; };
}
