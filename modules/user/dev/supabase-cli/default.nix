{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.dev.supabaseCli;

  supabase-wrapper = myLib.sops.mkSecretEnvWrapper {
    inherit config;
    pkgs = cfg.pkgs;
    name = "supabase";
    secret = cfg.tokenSops;
    envVar = "SUPABASE_ACCESS_TOKEN";
    exec = "${cfg.pkgs.supabase-cli}/bin/supabase";
  };
in
{
  options.userSettings.dev.supabaseCli = {
    enable = lib.mkEnableOption "Supabase CLI";
    pkgs = myLib.mkPkgsOption { inherit lib config; };

    tokenSops = lib.mkOption {
      type = lib.types.str;
      default = "supabase/access_token";
      description = ''
        Nom du secret sops contenant le token d'accès Supabase.
        A renseigner via `secrets edit <ce nom>`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = myLib.sops.assertAvailable {
      inherit config;
      optionName = "userSettings.dev.supabaseCli";
      need = "a besoin du secret sops (token Supabase)";
    };

    home.packages = [ supabase-wrapper ];

    sops.secrets.${cfg.tokenSops} = { };
  };
}
