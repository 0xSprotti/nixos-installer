#!/usr/bin/env bash
#
# check-vfio.sh — Smoke-Check fuer update-all.sh (Abschnitt 2b):
# Haengen alle per Kernel-Parameter deklarierten Passthrough-Geraete auch nach dem
# Update noch an vfio-pci? (Klassischer Bruch: Kernel-Update aendert die
# Treiber-Bindung, GPU-Passthrough reisst erst beim naechsten VM-Start sichtbar.)
#
# Quelle der Wahrheit ist /proc/cmdline ('vfio-pci.ids=…') — exakt das, was
# modules/vfio.nix ueber boot.kernelParams deklariert; kein Nix-Parsing noetig.
# Selbst-guardend: keine Deklaration auf diesem Host -> still Exit 0 (nicht zustaendig).
# Exit 1 = mindestens ein Geraet falsch gebunden; update-all.sh warnt, bricht nicht ab.
# Bewusst reines sysfs — keine Abhaengigkeit auf lspci/pciutils.
set -euo pipefail

ids=$(tr ' ' '\n' </proc/cmdline | sed -n 's/^vfio-pci\.ids=//p' | head -1)
[ -n "$ids" ] || exit 0

rc=0
IFS=',' read -ra id_list <<<"$ids"
for id in "${id_list[@]}"; do
  ven=$(printf '%s' "${id%%:*}" | tr '[:upper:]' '[:lower:]')
  dev=$(printf '%s' "${id##*:}" | tr '[:upper:]' '[:lower:]')
  found=0
  for pci in /sys/bus/pci/devices/*; do
    [ "$(cat "$pci/vendor" 2>/dev/null)" = "0x$ven" ] || continue
    [ "$(cat "$pci/device" 2>/dev/null)" = "0x$dev" ] || continue
    found=1
    drv=""
    if [ -L "$pci/driver" ]; then
      drv=$(basename "$(readlink -f "$pci/driver")")
    fi
    if [ "$drv" = "vfio-pci" ]; then
      printf '[check-vfio] %s (%s): an vfio-pci gebunden — OK\n' "$id" "${pci##*/}"
    else
      printf '[check-vfio] WARNUNG: %s (%s) haengt an "%s" statt vfio-pci — Passthrough gerissen?\n' \
        "$id" "${pci##*/}" "${drv:-kein Treiber}"
      rc=1
    fi
  done
  if [ "$found" -eq 0 ]; then
    printf '[check-vfio] WARNUNG: deklariertes Geraet %s nicht auf dem PCI-Bus gefunden.\n' "$id"
    rc=1
  fi
done
exit "$rc"
