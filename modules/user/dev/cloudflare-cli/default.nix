{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.dev.cloudflareCli;

  # CLOUDFLARE_API_TOKEN lu par wrangler lui-même (confirmé dans son bundle
  # JS) : le secret n'est jamais dans le store, seul le chemin déchiffré par
  # sops-nix (re-déchiffré à chaque activation) l'est.
  cloudflareTokenPath = config.sops.secrets.${cfg.tokenSops}.path;

  # writeShellApplication et pas writeShellScriptBin : il pose
  # `set -euo pipefail`, sans quoi un `cat` en échec (secret non déchiffré —
  # sops pas encore activé, user sans clé) laisse le token VIDE et wrangler
  # part NON AUTHENTIFIÉ, avec une erreur d'API trompeuse à l'arrivée. Bonus :
  # shellcheck passe dessus au build, ce que la CI ne fait que sur les *.sh.
  wrangler-wrapper = cfg.pkgs.writeShellApplication {
    name = "wrangler";
    runtimeInputs = [ cfg.pkgs.coreutils ];
    text = ''
      CLOUDFLARE_API_TOKEN="$(cat ${cloudflareTokenPath})"
      export CLOUDFLARE_API_TOKEN
      ${lib.optionalString (
        cfg.accountId != null
      ) "export CLOUDFLARE_ACCOUNT_ID=${lib.escapeShellArg cfg.accountId}"}
      exec ${cfg.pkgs.wrangler}/bin/wrangler "$@"
    '';
  };
in
{
  options.userSettings.dev.cloudflareCli = {
    enable = lib.mkEnableOption "Cloudflare CLI (wrangler)";
    pkgs = myLib.mkPkgsOption { inherit lib config; };

    tokenSops = lib.mkOption {
      type = lib.types.str;
      default = "cloudflare/wrangler_token";
      description = ''
        Nom du secret sops contenant le jeton API Cloudflare de wrangler.
        À créer avec `secrets edit cloudflare/wrangler_token`.

        PAS `cloudflare/api_token`, et l'écart n'est pas cosmétique : ce
        dernier est le jeton que lego lit EN ROOT sur le serveur pour la
        validation DNS-01, donc un jeton qui porte Zone:DNS:Edit sur la zone.
        Le déclarer ici le scellerait pour une clé de COMPTE, où il n'y a ni
        frontière root ni frontière de machine — n'importe quel code lancé sous
        cet utilisateur pourrait alors repointer les enregistrements du domaine
        et se faire émettre des certificats valides pour lui.

        Deux jetons distincts, et le problème de synchronisation qui avait
        motivé le fichier unique disparaît de lui-même : ce ne sont plus la
        même valeur, il n'y a donc plus rien à tenir aligné. Celui-ci se taille
        au plus juste de ce dont wrangler a besoin (Workers/Pages), jamais du
        DNS.
      '';
    };

    accountId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        ID de compte Cloudflare (pas un secret, juste un identifiant).
        Utile si le compte a plusieurs comptes, ou pour certaines commandes
        Workers/Pages. Visible sur dash.cloudflare.com (sidebar d'un domaine,
        ou page "Workers & Pages" > Account details).
      '';
      example = "023e105f4ecef8ad9ca31a8372d0c353";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = myLib.assertSopsAvailable {
      inherit config;
      optionName = "userSettings.dev.cloudflareCli";
      need = "a besoin du secret sops (token API Cloudflare)";
    };

    home.packages = [ wrangler-wrapper ];

    sops.secrets.${cfg.tokenSops} = { };
  };
}
