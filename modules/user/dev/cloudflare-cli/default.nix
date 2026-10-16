{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.dev.cloudflareCli;

  wrangler-wrapper = myLib.sops.mkSecretEnvWrapper {
    inherit config;
    pkgs = cfg.pkgs;
    name = "wrangler";
    secret = cfg.tokenSops;
    envVar = "CLOUDFLARE_API_TOKEN";
    env = lib.optionalAttrs (cfg.accountId != null) { CLOUDFLARE_ACCOUNT_ID = cfg.accountId; };
    exec = "${cfg.pkgs.wrangler}/bin/wrangler";
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
        Secret sops du jeton API Cloudflare de wrangler (`secrets edit cloudflare/wrangler_token`).

        Surtout pas `cloudflare/api_token` : c'est le jeton DNS-01 de lego
        (Zone:DNS:Edit), lu en root sur le serveur. Le mettre ici le donnerait
        à tout code lancé sous cet utilisateur. Ce jeton-ci se limite à
        Workers/Pages, jamais au DNS.
      '';
    };

    accountId = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "ID de compte Cloudflare (identifiant, pas un secret), visible sur dash.cloudflare.com.";
      example = "023e105f4ecef8ad9ca31a8372d0c353";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = myLib.sops.assertAvailable {
      inherit config;
      optionName = "userSettings.dev.cloudflareCli";
      need = "a besoin du secret sops (token API Cloudflare)";
    };

    home.packages = [ wrangler-wrapper ];

    sops.secrets.${cfg.tokenSops} = { };
  };
}
