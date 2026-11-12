#!/bin/sh
# A Kongi extension: Kongi runs this file and stops it when you turn the extension off.
# $KONGI is the kongi command (kongi notify / kongi run).
while true; do
  sleep 3000
  "$KONGI" notify "Time to stretch" "You've been at it for 50 minutes" --symbol figure.walk
done
