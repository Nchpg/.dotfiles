# Galerie HTML de tous les thèmes sélectionnables, ouverte par `theme` sans
# argument (cf. modules/system/stylix).
#
# Le manifeste vient de `pathByName` : la galerie affiche donc exactement ce
# que l'enum accepte. Le serveur le relit pour valider le nom reçu du
# navigateur, plutôt que d'écrire une chaîne arbitraire dans un .nix.
#
# Rendu au BUILD par render.py (PyYAML) plutôt qu'à l'éval : la page est un
# simple fichier du store, `theme` n'a rien à générer au runtime.
{ pkgs, themes }:

let
  # { nom = { path; source = "custom" | "upstream"; }; } — `source` alimente
  # le filtre « custom » de la galerie.
  #
  # "${path}" et pas `toString path` : l'interpolation copie le fichier dans
  # le store et renvoie CE chemin. `toString` donnerait le chemin source, que
  # le sandbox de build ne peut pas lire. No-op pour les schemes amont, déjà
  # dans le store.
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
        python3 ${./render.py} ${manifest} "$out"
      '';

  # $1 = profil, $2 = favoris : deux chemins DANS le clone (le serveur les
  # réécrit), pas dans le store. Pas de PyYAML ici, il ne lit que du JSON.
  server = pkgs.writeShellScript "theme-gallery-server" ''
    exec ${pkgs.python3}/bin/python3 ${./server.py} ${html} ${manifest} "$1" "$2"
  '';
in
{
  inherit html manifest server;
}
