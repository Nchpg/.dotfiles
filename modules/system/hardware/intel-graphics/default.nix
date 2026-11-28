{
  config,
  lib,
  pkgs-stable,
  pkgs-unstable,
  ...
}:

let
  cfg = config.systemSettings.hardware.intelGraphics;

  # Limite effective sur Meteor Lake : celle du MMIO, que règle thermald (la MSR, elle, reste à 200 W).
  pl1 = "/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw";
  pl1Micro = toString (cfg.powerLimit * 1000000);

  # Interrupteur du mode « gaming » (lg-control), écrit par le groupe wheel : sans lui, le profil performance reste
  # celui de power-profiles-daemon, sans plancher, sans plafond du processeur ni Wi-Fi toujours éveillé.
  maxSwitch = "/var/lib/power-limit/gaming";
  cpuMax = "/sys/devices/system/cpu/intel_pstate/max_perf_pct";
in
{
  options = {
    systemSettings.hardware.intelGraphics = {
      enable = lib.mkEnableOption "GPU Intel Arc/Xe (driver xe + OpenCL/Level-Zero/VA-API)";

      powerLimit = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        example = 16;
        description = ''
          Plancher de la limite de puissance longue durée (PL1, en watts), partagée par le CPU et le GPU, en mode
          « gaming » : profil performance de power-profiles-daemon et interrupteur /var/lib/power-limit/gaming à 1
          (lg-control). Ailleurs, et avec `null` : celle que thermald tire des tables du constructeur (DPTF), qui la
          fait varier avec la température. `null` : pas de mode gaming.
        '';
      };

      cpuMaxPerf = lib.mkOption {
        type = lib.types.nullOr (lib.types.ints.between 10 100);
        default = null;
        example = 70;
        description = ''
          Plafond du processeur en mode « gaming » (intel_pstate max_perf_pct, en % de sa fréquence maximale) : son
          turbo cède la puissance partagée au GPU, dans la même puce, et chauffe moins. `null` : pas de plafond.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {
        services.thermald.enable = true;

        services.xserver.videoDrivers = [ "modesetting" ];

        environment.systemPackages = [
          pkgs-stable.nvtopPackages.intel
          pkgs-stable.clinfo
        ];

        # iGPU Meteor Lake sur xe ; i915 peut geler le compute (inverser ces deux params).
        boot.kernelParams = [
          "i915.force_probe=!7d55"
          "xe.force_probe=7d55"
        ];
        boot.kernelModules = [ "xe" ];
        boot.initrd.kernelModules = [ "xe" ];

        hardware.graphics = {
          enable = true;
          extraPackages = [
            pkgs-unstable.intel-compute-runtime
            pkgs-unstable.level-zero
            # Média en stable : la libva stable (2.23) ne sait pas appeler le driver unstable.
            pkgs-stable.intel-media-driver
            pkgs-stable.vpl-gpu-rt
          ];
        };

        environment.sessionVariables = {
          LIBVA_DRIVER_NAME = "iHD";
        };

        programs.nix-ld.libraries = [ pkgs-stable.libva ];
      }

      # thermald (--adaptive) garde la gestion thermique : il baisse la PL1 quand un capteur chauffe, la remonte à
      # froid. En mode gaming, elle est relevée au plancher chaque seconde (contrôlée toutes les 30 s, thermald la
      # laissait jusqu'à 30 s à 12 W en pleine course), mais seulement loin des seuils critiques des capteurs : près
      # d'eux, thermald garde la main. En plancher : thermald peut accorder plus à froid ; en quittant ce mode, sa
      # valeur est rendue.
      (lib.mkIf (cfg.powerLimit != null) {
        assertions = [
          {
            assertion = config.services.power-profiles-daemon.enable;
            message = "systemSettings.hardware.intelGraphics.powerLimit suit le profil de power-profiles-daemon.";
          }
        ];

        systemd.services.power-limit = {
          description = "Mode gaming : PL1 d'au moins ${toString cfg.powerLimit} W${
            lib.optionalString (cfg.cpuMaxPerf != null) ", CPU à ${toString cfg.cpuMaxPerf} % max"
          }, Wi-Fi sans économie d'énergie";
          wantedBy = [ "multi-user.target" ];
          after = [
            "thermald.service"
            "power-profiles-daemon.service"
          ];
          unitConfig.ConditionPathExists = pl1;
          serviceConfig = {
            Restart = "always";
            RestartSec = "5s";
          };
          path = [ pkgs-stable.iw ];
          script = ''
            saved=/run/power-limit/thermald
            # Présent en mode gaming : lu par les affichages (lg-control, barre).
            floor=/run/power-limit/floor
            # Présent quand le plancher cède à la chaleur (capteurs ci-dessous) : affiché aussi.
            heat=/run/power-limit/heat
            mkdir -p /run/power-limit
            rm -f "$heat"

            # Capteurs gardés : toutes les zones thermiques qui ont un seuil critique. Sur le gram 16Z90S : SEN1, la
            # thermistance « CPU Sensor » près du processeur, et SEN2, « MB Sensor 1 », critiques à 80 °C (valeur de la
            # politique DPTF du constructeur, pas une limite des composants : le noyau ne fait que la journaliser) ; la
            # puce à 110 °C. Le plancher ne s'impose qu'à plus de 5 °C de chaque seuil (sous 75 °C pour SEN1, son seuil
            # « chaud », là où thermald accorde lui-même jusqu'à 25 W) : à 5 °C ou moins d'un seul, il laisse thermald
            # baisser la PL1, et ne revient qu'une fois tous redescendus à 8 °C sous leur seuil. Un capteur illisible
            # compte comme chaud. thermald, lui, garde toutes ses protections.
            sensors=()
            names=()
            limits=()
            for zone in /sys/class/thermal/thermal_zone*; do
              for trip in "$zone"/trip_point_*_type; do
                [ -e "$trip" ] || continue
                kind=""
                read -r kind < "$trip" || true
                [ "$kind" = critical ] || continue
                limit=""
                read -r limit < "''${trip%_type}_temp" || true
                if [[ $limit =~ ^[0-9]+$ ]] && [ "$limit" -gt 0 ]; then
                  name=""
                  read -r name < "$zone/type" || true
                  sensors+=("$zone/temp")
                  names+=("$name")
                  limits+=("$limit")
                fi
              done
            done
            echo "capteurs gardés :$(for i in "''${!sensors[@]}"; do printf ' %s (critique %s °C)' "''${names[$i]}" $((limits[i] / 1000)); done)"
            hot=0

            last=""
            tick=0
            while true; do
              # Mode gaming : l'interrupteur à 1 et le profil performance (que power-profiles-daemon garde dans son
              # fichier). Lus par les builtins de bash : la boucle ne coûte presque rien, dans le mode ou non.
              switch=""
              profile=""
              read -r switch < ${maxSwitch} || true
              while IFS= read -r line; do
                if [[ $line == Profile=* ]]; then profile=''${line#Profile=}; fi
              done < /var/lib/power-profiles-daemon/state.ini || true
              max=0
              if [ "$switch" = 1 ] && [ "$profile" = performance ]; then max=1; fi

              # Wi-Fi : la carte qui s'endort entre deux balises livre les paquets reçus par rafales, jusqu'à ~100 ms
              # en retard (manette de Dolphin par le VPN, jeux en ligne). Éveillée en mode gaming, économe ailleurs.
              # Au changement de mode, et toutes les 30 s : une reconnexion remet le réglage du pilote.
              if [ "$max" != "$last" ] || [ $((tick % 30)) = 0 ]; then
                for wireless in /sys/class/net/*/wireless; do
                  [ -e "$wireless" ] || continue
                  iw dev "$(basename "$(dirname "$wireless")")" set power_save "$([ "$max" = 1 ] && echo off || echo on)" || true
                done
              fi

              ${lib.optionalString (cfg.cpuMaxPerf != null) ''
                # Processeur plafonné en gaming : son turbo prenait la puissance partagée avec le GPU pour presque
                # rien côté jeu. Un plafond seulement (plus bas, on laisse) ; rendu à 100 % en quittant le mode.
                if [ -w ${cpuMax} ]; then
                  read -r cpu < ${cpuMax}
                  if [ "$max" = 1 ]; then
                    if [ "$cpu" -gt ${toString cfg.cpuMaxPerf} ]; then echo ${toString cfg.cpuMaxPerf} > ${cpuMax}; fi
                  elif [ "$cpu" = ${toString cfg.cpuMaxPerf} ]; then
                    echo 100 > ${cpuMax}
                  fi
                fi
              ''}
              near=0
              cool=1
              reason=""
              for i in "''${!sensors[@]}"; do
                t=""
                read -r t 2>/dev/null < "''${sensors[$i]}" || true
                if ! [[ $t =~ ^-?[0-9]+$ ]]; then
                  near=1
                  cool=0
                  reason+=" ''${names[$i]} illisible"
                  continue
                fi
                if [ "$t" -ge $((limits[i] - 5000)) ]; then
                  near=1
                  reason+=" ''${names[$i]} à $((t / 1000)) °C (critique $((limits[i] / 1000)) °C)"
                fi
                if [ "$t" -gt $((limits[i] - 8000)) ]; then cool=0; fi
              done
              if [ "$near" = 1 ] && [ "$hot" = 0 ]; then
                hot=1
                echo "plancher suspendu :$reason"
              elif [ "$cool" = 1 ] && [ "$hot" = 1 ]; then
                hot=0
                echo "plancher rétabli : capteurs redescendus"
              fi

              read -r current < ${pl1}
              if [ "$max" = 1 ]; then
                echo ${pl1Micro} > "$floor"
                if [ "$hot" = 1 ]; then
                  : > "$heat"
                else
                  rm -f "$heat"
                  if [ "$current" -lt ${pl1Micro} ]; then
                    echo "$current" > "$saved"
                    echo ${pl1Micro} > ${pl1}
                  fi
                fi
              elif [ -e "$floor" ]; then
                rm -f "$floor" "$heat"
                if [ "$current" = ${pl1Micro} ] && [ -s "$saved" ]; then
                  cat "$saved" > ${pl1}
                fi
              fi

              last=$max
              tick=$((tick + 1))
              sleep 1
            done
          '';
        };

        systemd.tmpfiles.rules = [
          "d /var/lib/power-limit 0755 root root -"
          "f ${maxSwitch} 0664 root wheel - 0"
        ];
      })
    ]
  );
}
