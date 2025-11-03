#!/usr/bin/env bash

BRIGHTNESS_STEPS=(1 5 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100)

current=$(brightnessctl get)
max=$(brightnessctl max)
percent=$((100 * current / max))

direction="$1"  # "up" or "down"

if [[ "$direction" == "down" ]]; then
  for ((i=${#BRIGHTNESS_STEPS[@]}-1; i>=0; i--)); do
    if [ "${BRIGHTNESS_STEPS[i]}" -lt "$percent" ]; then
      brightnessctl set "${BRIGHTNESS_STEPS[i]}%"
      break
    fi
  done
elif [[ "$direction" == "up" ]]; then
  for step in "${BRIGHTNESS_STEPS[@]}"; do
    if [ "$step" -gt "$percent" ]; then
      brightnessctl set "${step}%"
      break
    fi
  done
else
  echo "Usage: $0 up|down"
  exit 1
fi

