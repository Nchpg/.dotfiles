# Check du flake qui échoue à l'ÉVAL et pas au build : `nix flake check
# --no-build` évalue les checks sans construire leurs dérivations, donc un
# contrôle écrit dans un `runCommand` ne tournerait jamais en CI.
#
# `check` : { ok, report } — `report` est l'erreur levée si !ok, sinon le
# message affiché par la dérivation (triviale) quand on la construit.
lib:
{
  pkgs,
  name,
  check,
}:
lib.throwIf (!check.ok) check.report (
  pkgs.runCommand name { } ''
    echo ${lib.escapeShellArg check.report}
    touch $out
  ''
)
