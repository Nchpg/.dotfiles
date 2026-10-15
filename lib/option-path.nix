# La convention centrale du dépôt, en un seul endroit : un module rangé dans
# modules/<arbre>/<a>/<b>/ déclare ses options sous <namespace>.<a>.<b>, les
# tirets du dossier devenant du camelCase (vercel-cli -> vercelCli). Vérifiée
# par le check option-paths (cf. check-option-paths.nix), appliquée par les
# helpers qui déclarent un module à partir de son dossier (mkPackageModule).
lib: rec {
  kebabToCamel =
    name:
    let
      parts = lib.splitString "-" name;
    in
    lib.concatStrings (
      lib.imap0 (
        i: p: if i == 0 then p else lib.toUpper (lib.substring 0 1 p) + lib.substring 1 (-1) p
      ) parts
    );

  # Dossier d'un module home-manager (`./.` dans son default.nix) -> chemin
  # d'option sous userSettings, ex. …/modules/user/tui/lg-control ->
  # [ "tui" "lgControl" ]. `toString` d'un chemin ne copie rien dans le store.
  ofUserDir =
    dir:
    map kebabToCamel (lib.splitString "/" (lib.last (lib.splitString "/modules/user/" (toString dir))));
}
