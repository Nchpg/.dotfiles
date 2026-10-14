# La politique de ce dépôt-ci et le .sops.yaml du dépôt PRIVÉ disent la même
# chose : vérifié par le check `sops-policy` du flake (cf. flake.nix), dans la
# forme { ok, report } de check-option-paths.
#
# Ce que son absence laissait passer n'est pas anodin, et c'est exactement le
# mode de panne contre lequel tout le montage est écrit : une audience qui
# RÉTRÉCIT. Un host retiré de `deployments`, un peer supprimé, un secret qui
# cesse d'être déclaré par un profil — le .sops.yaml garde ses anciens
# destinataires, rien ne rescelle selon un .sops.yaml périmé, le rebuild
# réussit, et le rayon d'explosion reste large sans un mot. Sur-sceller n'a
# jamais produit d'erreur nulle part.
#
# On compare le SUFFIXE du fichier à partir de son marqueur : ce qui précède,
# ce sont les ancres de clés du dépôt privé, qui s'éditent à la main et ne
# regardent pas ce dépôt-ci.
lib:

{
  # Sortie de sopsPolicy.generate.
  expected,
  # Marqueur du bloc généré (sopsPolicy.marker).
  marker,
  # Chemin du .sops.yaml du dépôt de secrets.
  file,
}:

let
  parts = lib.splitString marker (builtins.readFile file);
  found = lib.length parts > 1;
  block = marker + lib.concatStringsSep marker (lib.tail parts);

  # Ancres définies (avant le marqueur) et citées (par la politique) : une
  # ancre citée mais absente rend le fichier illisible pour sops (« unknown
  # anchor »), alors que le bloc, lui, serait conforme.
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
