# Compare le SUFFIXE du .sops.yaml à partir du marqueur ; les ancres au-dessus sont éditées à la main.
lib:

{
  expected,
  marker,
  file,
}:

let
  parts = lib.splitString marker (builtins.readFile file);
  found = lib.length parts > 1;
  block = marker + lib.concatStringsSep marker (lib.tail parts);

  namesIn =
    re: text:
    lib.unique (
      lib.concatMap (l: lib.optionals (builtins.match re l != null) (builtins.match re l)) (
        lib.splitString "\n" text
      )
    );
  defined = namesIn "[[:space:]]*-[[:space:]]+&([A-Za-z0-9_-]+)[[:space:]]+age1.*" (
    builtins.head parts
  );
  cited = namesIn "[[:space:]]*-[[:space:]]+[*]([A-Za-z0-9_-]+).*" expected;
  missingAnchors = lib.subtractLists defined cited;

  problem =
    if !(builtins.pathExists file) then
      "le dépôt de secrets ne contient pas de .sops.yaml."
    else if !found then
      "le .sops.yaml du dépôt de secrets ne contient pas le bloc généré (marqueur « ${marker} » absent)."
    else if missingAnchors != [ ] then
      "la politique cite des ancres que le .sops.yaml ne définit pas : ${lib.concatStringsSep ", " missingAnchors} (machine dans deployments pas encore inscrite ?)."
    else if block != expected then
      "le bloc généré du .sops.yaml ne correspond plus à ce que les configurations déclarent."
    else
      null;
in
{
  ok = problem == null;
  report =
    if problem == null then
      "politique sops conforme au .sops.yaml du dépôt de secrets"
    else
      ''
        sops-policy : ${toString problem}

        Les destinataires déployés ne sont donc plus ceux que ce dépôt calcule, et
        une audience trop LARGE ne se signalerait par aucune autre erreur.

          secrets policy

        depuis une machine qui peut encore ouvrir ces fichiers : elle remplace le bloc
        généré du .sops.yaml du dépôt privé, rescelle si besoin et synchronise.
      '';
}
