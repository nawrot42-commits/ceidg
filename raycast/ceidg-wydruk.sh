#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Wydruk CEIDG
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🏢
# @raycast.packageName CEIDG
# @raycast.argument1 { "type": "text", "placeholder": "NIP" }

# Documentation:
# @raycast.description Pobiera oficjalny wydruk PDF z CEIDG dla podanego NIP

NIP=$(printf '%s' "$1" | tr -cd '0-9')
if [ ${#NIP} -ne 10 ]; then
  echo "NIP musi mieć 10 cyfr"
  exit 1
fi

open "ceidgwydruk://$NIP" 2>/dev/null || open -a "$HOME/Applications/CEIDGWydruk.app" --args "$NIP"
echo "Pobieram wydruk CEIDG dla $NIP…"
