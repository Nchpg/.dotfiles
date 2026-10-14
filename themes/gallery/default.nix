# Galerie HTML de tous les thèmes sélectionnables, ouverte par `theme` sans
# argument. Manifeste = `pathByName`, revalidé par le serveur côté nom reçu
# du navigateur. Rendu au BUILD par render.py (PyYAML), pas à l'éval.
{ pkgs, themes }:

let
  # "${path}" et pas `toString path` : l'interpolation copie dans le store et
  # renvoie CE chemin, lisible par le sandbox de build (toString donnerait le
  # chemin source). `source` alimente le filtre "custom" de la galerie.
  manifest = pkgs.writeText "themes-manifest.json" (
    builtins.toJSON (
      builtins.mapAttrs (name: path: {
        path = "${path}";
        source = if builtins.elem name themes.localNames then "custom" else "upstream";
      }) themes.pathByName
    )
  );

  python = pkgs.python3.withPackages (ps: [ ps.pyyaml ]);

  html =
    pkgs.runCommand "themes-gallery.html"
      {
        nativeBuildInputs = [ python ];
      }
      ''
        python3 ${./render.py} ${manifest} "$out" ${./gallery.css} ${./gallery.js}
      '';

  # $1 = profil, $2 = favoris : chemins DANS le clone (réécrits par le
  # serveur), pas dans le store.
  server = pkgs.writeShellScript "theme-gallery-server" ''
    exec ${pkgs.python3}/bin/python3 ${./server.py} ${html} ${manifest} "$1" "$2"
  '';
in
{
  inherit html manifest server;
}
