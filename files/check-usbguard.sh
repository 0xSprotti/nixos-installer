#!/usr/bin/env bash
#
# check-usbguard.sh — Smoke-Check nach Host-Updates (laeuft automatisch in
# update-all.sh, Abschnitt 2b). Prueft NICHT auf Repo-Drift (unmoeglich: die
# Regeldatei liegt im read-only Nix-Store), sondern auf den realen Fehlerfall:
#   1) usbguard-Daemon laeuft nach dem Update noch
#   2) KEIN Geraet ist geblockt — auf einem Host mit gepinnter Whitelist heisst
#      ein geblocktes Geraet: interne Hardware (Bluetooth/Webcam/kuenftig WWAN)
#      ist still tot, weil ein Update die Enumeration geaendert hat oder die
#      Regeldatei beim Editieren beschaedigt wurde.
#
# Muster wie alle check-*.sh: selbst-guardend — Host ohne USBGuard -> still Exit 0;
# Warnung -> Exit 1 (update-all.sh warnt nur, bricht nie ab).
set -euo pipefail
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP

warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }

# Nicht zustaendig: kein USBGuard auf diesem Host (Unit existiert nicht) -> still ok.
if ! systemctl cat usbguard >/dev/null 2>&1; then
  exit 0
fi

if ! systemctl is-active --quiet usbguard; then
  warn "usbguard: Unit existiert, Daemon laeuft aber NICHT (systemctl status usbguard)."
  exit 1
fi

if ! command -v usbguard >/dev/null 2>&1; then
  warn "usbguard: Daemon aktiv, aber CLI nicht im PATH — Zustand nicht pruefbar."
  exit 1
fi

blocked="$(usbguard list-devices --blocked 2>/dev/null || true)"
if [ -n "$blocked" ]; then
  warn "usbguard: geblockte Geraete nach dem Update — interne Hardware evtl. still tot:"
  printf '%s\n' "$blocked"
  warn "Regel nachziehen: bash usbguard-sync.sh --add   (Details: README-hardening.md)"
  exit 1
fi

ok "usbguard: Daemon aktiv, keine geblockten Geraete."
