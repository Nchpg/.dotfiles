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

  # writeShellApplication : `set -euo pipefail` obligatoire ici, cf. le même
  # commentaire dans dev/cloudflare-cli — sans lui, un secret non déchiffré
  # donne un token vide et un CLI qui part non authentifié en silence.
  supabase-wrapper = cfg.pkgs.writeShellApplication {
    name = "supabase";
    runtimeInputs = [ cfg.pkgs.coreutils ];
    text = ''
      SUPABASE_ACCESS_TOKEN="$(cat ${supabaseTokenPath})"
      export SUPABASE_ACCESS_TOKEN
      exec ${cfg.pkgs.supabase-cli}/bin/supabase "$@"
    '';
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
        A renseigner via `secrets user` sous la cle correspondante.
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
