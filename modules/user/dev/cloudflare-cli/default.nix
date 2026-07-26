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
      default = "cloudflare/api_token";
      description = ''
        Nom du secret sops contenant le token API Cloudflare.
        A renseigner via `sops secrets/secrets.yaml` sous la cle correspondante.
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
