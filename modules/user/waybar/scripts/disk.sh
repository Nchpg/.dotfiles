#!/usr/bin/env bash
# Stockage racine. On utilise `df -h` (unités courtes : "12G" -> "12Go")
# plutôt que le module disk natif de waybar qui affiche du "GiB".
# Repris de sway-bar.sh. Icône au début pour rester homogène avec les autres.

df -h / | awk 'NR==2 {print "󰉋   " $3 "o : " $5}'
