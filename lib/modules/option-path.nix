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

  ofUserDir =
    dir:
    map kebabToCamel (lib.splitString "/" (lib.last (lib.splitString "/modules/user/" (toString dir))));
}
