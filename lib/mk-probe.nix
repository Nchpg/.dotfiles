# Sonde périodique : un script oneshot, son timer, et le signalement de son
# échec. Rend un fragment de configuration à fusionner :
#
#   config = lib.mkMerge [
#     (myLib.mkProbe pkgs-stable {
#       name = "acme-expiry-check";
#       description = "Vérifie …";
#       timerDescription = "Sonde quotidienne …";
#       interval = "daily";
#       runtimeInputs = [ pkgs-stable.openssl ];
#       text = ''…'';
#       serviceConfig = { DynamicUser = true; };
#     })
#   ];
#
# CONTRÔLE D'UN ÉTAT, par opposition à une notification d'échec qui réagit à
# un ÉVÉNEMENT et ne peut donc rien dire quand il ne se passe rien. La sonde ne
# notifie rien elle-même : elle SORT EN ERREUR, et le `onFailure` ordinaire
# (`notify.discord.units`) fait le reste. Une brique de moins à écrire, et la
# sonde reste utilisable à la main.
lib: pkgs:
{
  name,
  description,
  timerDescription,
  interval,
  text,
  runtimeInputs ? [ ],
  after ? [ ],
  wants ? [ ],
  serviceConfig ? { },
}:
let
  script = pkgs.writeShellApplication { inherit name runtimeInputs text; };
in
{
  systemd.services.${name} = {
    inherit description after wants;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = lib.getExe script;
    }
    // serviceConfig;
  };

  systemd.timers.${name} = {
    description = timerDescription;
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = interval;
      # Rattrape le passage manqué si la machine était éteinte : un contrôle
      # d'état qui saute silencieusement ne vaut pas mieux que pas de contrôle,
      # et une absence prolongée créerait le trou que la sonde doit fermer.
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  systemSettings.notify.discord.units = [ name ];
}
