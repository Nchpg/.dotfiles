# Wrapper « secret sops -> variable d'environnement » autour d'un CLI qui lit
# son jeton dans l'environnement (vercel, supabase, wrangler...). Le secret
# n'est jamais dans le store, seul le chemin déchiffré par sops-nix
# (re-déchiffré à chaque activation) l'est.
#
# writeShellApplication et pas writeShellScriptBin : il pose
# `set -euo pipefail`, sans quoi un `cat` en échec (secret non déchiffré —
# sops pas encore activé, user sans clé) laisse le jeton VIDE et le CLI part
# NON AUTHENTIFIÉ, avec une erreur d'API trompeuse à l'arrivée. Bonus :
# shellcheck passe dessus au build, ce que la CI ne fait que sur les *.sh.
#
# Le module garde la déclaration du secret (`sops.secrets.<secret> = { }`)
# et l'assertion myLib.sops.assertAvailable.
lib:
{
  pkgs,
  config,
  # Nom de la commande produite.
  name,
  # Nom du secret sops (ex. cfg.tokenSops).
  secret,
  # Variable d'environnement qui reçoit le secret.
  envVar,
  # Ligne de commande lancée (exec), arguments de l'utilisateur ajoutés.
  exec,
  # Variables supplémentaires, non secrètes (valeurs échappées).
  env ? { },
}:
pkgs.writeShellApplication {
  inherit name;
  runtimeInputs = [ pkgs.coreutils ];
  text = ''
    ${envVar}="$(cat ${config.sops.secrets.${secret}.path})"
    export ${envVar}
    ${
      lib.concatStrings (lib.mapAttrsToList (n: v: "export ${n}=${lib.escapeShellArg v}\n") env)
    }exec ${exec} "$@"
  '';
}
