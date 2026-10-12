{
  config,
  lib,
  pkgs-stable,
  ...
}:

# Disques : entretien et santé pour TOUS les hosts, intégration au gestionnaire
# de fichiers pour les seuls postes qui en ont un.
#
# CE DÉCOUPAGE N'EST PAS COSMÉTIQUE, et il vient d'une observation. Ce module
# était inconditionnel de bout en bout — contrairement au principe du dépôt,
# « chaque module est inerte tant que son option enable n'est pas activée » —
# si bien que le serveur headless installait Thunar, gvfs, xfconf et udisks2.
#
# Le symptôme n'était pas l'encombrement mais du BRUIT, découvert en lisant les
# journaux dans Grafana : dbus refuse un nom déjà enregistré et le consigne en
# `error`, une fois par fichier de service et par chemin où il apparaît — le
# paquet lui-même ET `system-path`. Chaque activation produisait ainsi une
# trentaine d'erreurs sur des services de bureau qu'aucune session n'ouvrira
# jamais, noyant le panneau « erreurs et avertissements » au point de le rendre
# inutile. Une erreur qu'on apprend à ignorer est une erreur qui masquera la
# suivante.
#
# La FRONTIÈRE : ce qui protège la donnée reste partout (smartd, fstrim), ce qui
# sert à cliquer sur une clé USB suit `systemSettings.desktop.enable`.
let
  desktop = config.systemSettings.desktop.enable;
in
{
  # ------------------------------------------------------- tous les hosts

  boot.supportedFilesystems = [ "ntfs" ];

  # ext4 sans option discard : rien d'autre ne trimait le SSD.
  services.fstrim.enable = true;

  # Alerte via le journal si les compteurs SMART se dégradent (signal
  # précoce avant panne). Notification desktop via systembus-notify — déjà
  # activé par earlyoom, le laisser à false ici créerait un conflit d'éval.
  #
  # SUR UN SERVEUR, ce canal ne va nulle part : `systembus-notify` s'adresse à
  # une session graphique, et il n'y en a pas. C'est précisément le trou que
  # `systemSettings.monitoring.disks` comble, en relevant les mêmes compteurs
  # par l'exporteur smartctl pour les router vers Discord. Les deux coexistent
  # sans se gêner, smartd gardant ce que l'exporteur ne sait pas faire : les
  # autotests périodiques.
  services.smartd = {
    enable = true;
    notifications.systembus-notify.enable = true;
  };

  # ------------------------------------------------- postes de travail seuls

  # udisks2 : montage sans root (D-Bus + polkit). Thunar en gestionnaire.
  services.udisks2.enable = lib.mkIf desktop true;

  # Couche "volumes" de Thunar (montage USB, corbeille, MTP) : dépendance
  # cachée du module GNOME, à activer explicitement.
  services.gvfs.enable = lib.mkIf desktop true;
  # Binaire que gvfsd-wsdd lance pour découvrir les partages Windows/SMB dans
  # « Réseau » : sans lui, échec à chaque ouverture (« Failed to spawn the
  # wsdd daemon »). Client seul : rien n'est annoncé ni ouvert sur le réseau.
  environment.systemPackages = lib.mkIf desktop [ pkgs-stable.wsdd ];

  programs.thunar.enable = lib.mkIf desktop true;
  # Service de miniatures que Thunar interroge par D-Bus : sans lui, pas
  # d'aperçus et une erreur « not activatable » à chaque dossier ouvert.
  services.tumbler.enable = lib.mkIf desktop true;

  # Les commandes admin NVMe exigent CAP_SYS_ADMIN : waybar (user) ne peut
  # pas appeler smartctl lui-même, d'où cet export périodique vers
  # /run/nvme-health/ (lisible sans root), consommé par disk.sh.
  #
  # Réservé au bureau parce que son SEUL consommateur est waybar, qui n'existe
  # que là. Sur le serveur il ne tournait déjà à vide — think n'a pas de NVMe,
  # donc la condition de chemin ci-dessous le neutralisait — mais une unité et
  # un timer qui existent sans avoir de raison d'être finissent par être lus
  # comme s'ils en avaient une.
  systemd.services.nvme-health-export = lib.mkIf desktop {
    description = "Exporte la santé SMART des NVMe vers /run/nvme-health";
    unitConfig.ConditionPathExistsGlob = "/dev/nvme[0-9]"; # pas de NVMe -> pas d'unit failed
    serviceConfig = {
      Type = "oneshot";
      RuntimeDirectory = "nvme-health";
      RuntimeDirectoryPreserve = true; # doit survivre entre deux ticks du timer
      ExecStart = pkgs-stable.writeShellScript "nvme-health-export" ''
        set -euo pipefail
        PATH=${pkgs-stable.smartmontools}/bin:${pkgs-stable.coreutils}/bin
        for dev in /dev/nvme[0-9]; do
          [ -e "$dev" ] || continue
          out="/run/nvme-health/$(basename "$dev").json"
          # smartctl sort != 0 sur certains warnings SMART, JSON quand même valide.
          smartctl -H -A --json=c "$dev" > "$out.tmp" || true
          [ -s "$out.tmp" ] && mv "$out.tmp" "$out"
        done
      '';
    };
  };

  systemd.timers.nvme-health-export = lib.mkIf desktop {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "1min";
      OnUnitActiveSec = "5min";
    };
  };
}
