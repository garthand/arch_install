#!/bin/bash
set -euo pipefail

systemd-pcrlock make-policy
drive=$(lsblk | grep -B 1 crypt | head -1 | awk -F '─' '{print $2}' | awk '{print $1}')
systemd-cryptenroll --tpm2-device=auto --tpm2-pcrlock=/var/lib/systemd/pcrlock.json /dev/"$drive"
