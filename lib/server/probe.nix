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
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  systemSettings.notify.discord.units = [ name ];
}
