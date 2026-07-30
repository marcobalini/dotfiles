#!/usr/bin/env bash

for d in */; do
  if [ -d "$d/.git" ]; then
    (
      echo "Syncing $d..."
      git -C "$d" pull
    ) &
  fi
done

wait

