{
  config,
  lib,
  myLib,
  ...
}:

let
  cfg = config.userSettings.dev.supabaseCli;

  # SUPABASE_ACCESS_TOKEN lu par le CLI lui-même (confirmé dans son binaire) :
  # le secret n'est jamais dans le store, seul le chemin déchiffré par
  # sops-nix (re-déchiffré à chaque activation) l'est.
  supabaseTokenPath = config.sops.secrets.${cfg.tokenSops}.path;

  supabase-wrapper = cfg.pkgs.writeShellScriptBin "supabase" ''
    export SUPABASE_ACCESS_TOKEN="$(cat ${supabaseTokenPath})"
    exec ${cfg.pkgs.supabase-cli}/bin/supabase "$@"
  '';
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
        A renseigner via `sops secrets/secrets.yaml` sous la cle correspondante.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = myLib.assertSopsAvailable {
      inherit config;
      optionName = "userSettings.dev.supabaseCli";
      need = "a besoin du secret sops (token Supabase)";
    };

    home.packages = [ supabase-wrapper ];

    sops.secrets.${cfg.tokenSops} = { };
  };
}
