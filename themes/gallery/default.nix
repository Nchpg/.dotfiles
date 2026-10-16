{ pkgs, themes }:

let
  # "${path}" (et non toString) copie dans le store : lisible par le sandbox.
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

  server = pkgs.writeShellScript "theme-gallery-server" ''
    exec ${pkgs.python3}/bin/python3 ${./server.py} ${html} ${manifest} "$1" "$2"
  '';
in
{
  inherit html manifest server;
}
