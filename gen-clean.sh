#!/usr/bin/env bash

# Script pour nettoyer les générations système NixOS (avec flake + Home Manager)
set -e

echo "Choisissez le mode de nettoyage :"
echo "1) Supprimer les générations plus anciennes que X jours"
echo "2) Ne garder que les N générations les plus récentes"
read -p "Votre choix (1 ou 2) : " MODE

SYSTEM_PROFILE="/nix/var/nix/profiles/system"

if [[ "$MODE" == "1" ]]; then
    read -p "Nombre de jours : " DAYS
    if ! [[ "$DAYS" =~ ^[0-9]+$ ]]; then
      echo "Erreur : '$DAYS' n'est pas un nombre valide."
      exit 1
    fi
    echo "Suppression des générations système plus anciennes que $DAYS jours..."

    # Supprimer les générations système anciennes
    sudo nix-env -p "$SYSTEM_PROFILE" --delete-generations +"$DAYS"d

elif [[ "$MODE" == "2" ]]; then
    read -p "Nombre de générations à garder : " N
    if ! [[ "$N" =~ ^[0-9]+$ ]]; then
      echo "Erreur : '$N' n'est pas un nombre valide."
      exit 1
    fi
    echo "Suppression des générations système sauf les $N plus récentes..."

    sudo nix-env -p "$SYSTEM_PROFILE" --delete-generations +$N

else
    echo "Choix invalide."
    exit 1
fi

# Garbage collection pour libérer l'espace
echo "Exécution de la garbage collection..."
sudo nix-collect-garbage -d

# Optionnel : rebuild du système pour mettre à jour GRUB et Home Manager
echo "Rebuilding le système et Home Manager via la flake..."
sudo nixos-rebuild switch --flake .

echo "Nettoyage et rebuild terminés."
