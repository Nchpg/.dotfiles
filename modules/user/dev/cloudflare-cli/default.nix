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

  wrangler-wrapper = cfg.pkgs.writeShellScriptBin "wrangler" ''
    export CLOUDFLARE_API_TOKEN="$(cat ${cloudflareTokenPath})"
    ${lib.optionalString (
      cfg.accountId != null
    ) "export CLOUDFLARE_ACCOUNT_ID=${lib.escapeShellArg cfg.accountId}"}
    exec ${cfg.pkgs.wrangler}/bin/wrangler "$@"
  '';
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
