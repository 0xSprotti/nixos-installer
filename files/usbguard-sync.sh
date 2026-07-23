#!/usr/bin/env bash
#
# usbguard-sync.sh — pflegt die gepinnte USBGuard-Whitelist des Hosts
#   (hosts/<host>/usbguard-rules.conf) aus dem laufenden Daemon-Zustand.
#
# Aufruf (irgendwo im Repo):
#   bash usbguard-sync.sh --init         Erstanlage: hosts/<host>/usbguard-rules.conf aus dem
#                                        Ist-Zustand erzeugen (usbguard generate-policy; braucht
#                                        KEINEN laufenden Daemon — fuer neue Hosts VOR dem
#                                        Aktivieren von hardening.usbguard.rulesFile)
#   bash usbguard-sync.sh --status       geblockte Geraete anzeigen (nur lesen)
#   bash usbguard-sync.sh --add          geblockte Geraete listen -> Auswahl -> Regel anhaengen
#   bash usbguard-sync.sh --add <nr>     Geraet <nr> (Nummer aus --status) direkt anhaengen
#
# Semantik: haengt NUR die allow-Zeile (+ Kommentar) an die Repo-Datei an und zeigt
# den git-Diff. KEIN Auto-Rebuild, KEIN Auto-Commit — Aktivieren bleibt eine bewusste
# Entscheidung (git add -A && sudo nixos-rebuild switch --flake .#<host>), wie bei
# allen Gates in diesem Repo. Regeln entstehen ausschliesslich hier — nie per
# 'usbguard append-rule' am Repo vorbei (scheitert am read-only Nix-Store ohnehin).
#
set -euo pipefail

# setuid-sudo-sicherer PATH (Muster aus update-all.sh; hier fuer kuenftige Kontexte)
export PATH="/run/wrappers/bin:$PATH"
trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP

info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argumente
# ---------------------------------------------------------------------------
MODE=""; DEV_NR=""
case "${1:-}" in
  --init)   MODE=init ;;
  --status) MODE=status ;;
  --add)    MODE=add; DEV_NR="${2:-}" ;;
  -h|--help|"") sed -n '2,20p' "$0"; exit 0 ;;
  *) die "Unbekanntes Argument: $1 (siehe --help)" ;;
esac
if [ -n "$DEV_NR" ] && ! [[ "$DEV_NR" =~ ^[0-9]+$ ]]; then
  die "Geraete-Nummer muss numerisch sein: '$DEV_NR'"
fi

# ---------------------------------------------------------------------------
# Ins Repo-Wurzelverzeichnis + Vorbedingungen
# ---------------------------------------------------------------------------
if [ ! -f flake.nix ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$root" ] && cd "$root"
fi
[ -f flake.nix ] || die "Keine flake.nix gefunden — bitte im Repo (oder Repo-Root) ausfuehren."

HOST="$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null)"
[ -n "$HOST" ] || die "Hostnamen nicht ermittelbar."
RULES_FILE="hosts/${HOST}/usbguard-rules.conf"

# ---------------------------------------------------------------------------
# --init: Erstanlage der Whitelist aus dem Ist-Zustand (generate-policy liest
# sysfs direkt — braucht root, aber KEINEN laufenden Daemon; laeuft also auf
# einem frischen Host, BEVOR hardening.usbguard.rulesFile gesetzt ist).
# Ist die usbguard-CLI (noch) nicht installiert, wird sie fluechtig aus nixpkgs
# geholt (nix build, ohne Systemaenderung).
# ---------------------------------------------------------------------------
if [ "$MODE" = "init" ]; then
  [ -d "hosts/${HOST}" ] || die "hosts/${HOST}/ existiert nicht — falscher Host oder falsches Repo?"
  [ ! -e "$RULES_FILE" ] || die "${RULES_FILE} existiert bereits — Pflege ueber --status/--add, nicht --init."

  if command -v usbguard >/dev/null 2>&1; then
    usbguard_bin="$(command -v usbguard)"
  else
    info "usbguard-CLI nicht installiert — hole sie fluechtig aus nixpkgs…"
    store_path="$(nix --extra-experimental-features 'nix-command flakes' \
                    build --no-link --print-out-paths nixpkgs#usbguard)" \
      || die "nixpkgs#usbguard nicht baubar/beziehbar (offline?)."
    usbguard_bin="${store_path}/bin/usbguard"
    [ -x "$usbguard_bin" ] || die "usbguard-Binary nicht gefunden unter ${store_path}/bin."
  fi

  info "Erzeuge Whitelist aus dem Ist-Zustand (sudo usbguard generate-policy)…"
  {
    printf '# %s — gepinnte USBGuard-Whitelist fuer %s.\n' "$RULES_FILE" "$HOST"
    printf '# Quelle: usbguard generate-policy am %s via usbguard-sync.sh --init.\n' "$(date +%Y-%m-%d)"
    printf '# Alles, was hier NICHT steht, wird geblockt. Pflege: usbguard-sync.sh --add\n'
    printf '# (nie lokal per append-rule — Regeln kommen ausschliesslich aus dem Repo).\n\n'
    sudo "$usbguard_bin" generate-policy
  } > "$RULES_FILE" || { rm -f "$RULES_FILE"; die "generate-policy fehlgeschlagen — ${RULES_FILE} nicht angelegt."; }
  # Leerer Regelteil waere fatal (Default-Block ohne eine einzige allow-Zeile).
  grep -q '^allow ' "$RULES_FILE" \
    || { rm -f "$RULES_FILE"; die "generate-policy lieferte keine allow-Regeln — Abbruch (Datei verworfen)."; }

  ok "Whitelist angelegt: ${RULES_FILE} ($(grep -c '^allow ' "$RULES_FILE") Regeln)."
  info "Naechste Schritte (README-hardening.md, Abschnitt Einbindung):"
  printf '  1) In hosts/%s/configuration.nix: modules/hardening.nix importieren und setzen:\n' "$HOST"
  printf '       hardening.usbguard.rulesFile = ./usbguard-rules.conf;\n'
  printf '  2) git add -A   (Flake sieht nur getrackte Dateien!)\n'
  printf '  3) sudo nixos-rebuild switch --flake .#%s\n' "$HOST"
  printf '  4) Verifikation: usbguard list-devices --blocked   -> muss leer sein\n'
  exit 0
fi

# ---------------------------------------------------------------------------
# Vorbedingungen fuer --status/--add: laufender Daemon + CLI
# ---------------------------------------------------------------------------
command -v usbguard >/dev/null 2>&1 \
  || die "usbguard-CLI nicht gefunden — laeuft dieser Host mit hardening.nix + rulesFile?"
systemctl is-active --quiet usbguard \
  || die "usbguard-Daemon ist nicht aktiv (systemctl status usbguard)."

# ---------------------------------------------------------------------------
# Geblockte Geraete einsammeln (IPC laeuft ueber die wheel-Gruppe, kein sudo noetig).
# Ausgabeformat je Zeile:  <nr>: block id 1234:5678 serial "..." name "..." hash "..." ...
# ---------------------------------------------------------------------------
blocked="$(usbguard list-devices --blocked 2>/dev/null || true)"

if [ "$MODE" = "status" ]; then
  if [ -z "$blocked" ]; then
    ok "Keine geblockten Geraete — Whitelist deckt alles Angesteckte ab."
  else
    info "Geblockte Geraete (Nummer fuer '--add <nr>'):"
    printf '%s\n' "$blocked"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# --add: Auswahl (interaktiv, falls keine Nummer uebergeben)
# ---------------------------------------------------------------------------
[ -f "$RULES_FILE" ] || die "Regeldatei fehlt: $RULES_FILE — erst anlegen (README-hardening.md)."
[ -n "$blocked" ] || { ok "Keine geblockten Geraete — nichts hinzuzufuegen."; exit 0; }

if [ -z "$DEV_NR" ]; then
  [ -t 0 ] || die "Interaktive Auswahl braucht ein Terminal — oder direkt: --add <nr>."
  info "Geblockte Geraete:"
  printf '%s\n' "$blocked"
  read -rp "$(printf '\033[1;34m[?]\033[0m Nummer des zu erlaubenden Geraets: ')" DEV_NR || DEV_NR=""
  [[ "$DEV_NR" =~ ^[0-9]+$ ]] || die "Keine gueltige Nummer."
fi

# Zeile der gewaehlten Nummer greifen: "<nr>: block <regel...>" -> "allow <regel...>"
line="$(printf '%s\n' "$blocked" | grep -E "^[[:space:]]*${DEV_NR}:[[:space:]]" || true)"
[ -n "$line" ] || die "Geraet ${DEV_NR} nicht unter den geblockten Geraeten (Liste veraltet? --status)."
rule="allow $(printf '%s' "$line" | sed -E 's/^[[:space:]]*[0-9]+:[[:space:]]*block[[:space:]]+//')"

info "Neue Regel:"
printf '  %s\n' "$rule"

# Duplikat-Schutz: identische Regel schon in der Datei?
if grep -qF "$rule" "$RULES_FILE"; then
  warn "Identische Regel steht bereits in ${RULES_FILE} — nichts zu tun."
  warn "(Geraet trotzdem geblockt? Dann laeuft der Host noch auf altem Stand -> rebuild.)"
  exit 0
fi

# Kommentar erfragen (Pflichtdisziplin der Datei: jede Regel traegt ihr Wozu)
comment=""
if [ -t 0 ]; then
  read -rp "$(printf '\033[1;34m[?]\033[0m Kommentar (wozu ist das Geraet?): ')" comment || comment=""
fi
[ -n "$comment" ] || comment="TODO: Zweck nachtragen (usbguard-sync.sh $(date +%Y-%m-%d))"

{
  printf '\n# --- %s (hinzugefuegt %s via usbguard-sync.sh) ---\n' "$comment" "$(date +%Y-%m-%d)"
  printf '%s\n' "$rule"
} >> "$RULES_FILE"
ok "Regel angehaengt an ${RULES_FILE}."

info "Aenderung (git diff):"
git --no-pager diff -- "$RULES_FILE" || true

info "Aktivieren (bewusste Entscheidung, kein Automatismus):"
printf '  git add -A && sudo nixos-rebuild switch --flake .#%s\n' "$HOST"
