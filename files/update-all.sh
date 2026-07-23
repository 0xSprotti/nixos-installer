#!/usr/bin/env bash
#
# update-all.sh — bumpt den Flake und aktualisiert ALLES auf einen Schlag:
#  0b) Payload-Abgleich: Quellen aus payload-sources.conf (Basis/Extensions) clonen,
#      files/ gegen das Repo diffen -> Diff + [J/n]-Gate -> atomar uebernehmen +
#      Provenienz-Commit 'payload: <name> -> <rev>'. Ohne die Datei: stiller Skip
#      (Feature schlaeft, bis install.sh/du sie anlegt). Doku: docs/README-payload.md
#   1) nix flake update   (hebt nixpkgs & Co. -> neues Zed, Plasma, claude-code, Kernel …)
#   2) Host erst BAUEN (ohne Aktivierung) -> Paket-Diff zeigen -> nachfragen -> aktivieren
#      (bei 'n' oder Fehler wird der flake.lock-Bump verworfen -> kein Drift Repo <-> System)
#  2b) Smoke-Checks direkt nach der Aktivierung: systemd-Zustand + alle check-*.sh im
#      Repo-Root (warnen nur, brechen nie ab — Rollback bleibt bewusste Entscheidung);
#      erkennt zusaetzlich einen Kernel-Bump und erinnert am Skriptende an den
#      noetigen Reboot (BSI SYS.2.3.A4 — neuer Kernel laeuft erst nach Neustart)
#  2c) Rabby-Pin (browser-vm): gepinnte Version gegen die neueste GitHub-Release
#      pruefen; Bump nur nach [j/N]-Gate (Default NEIN — Wallet-Update bleibt eine
#      bewusste Entscheidung, das Skript automatisiert nur die Mechanik)
#   3) VM-Images Stand-gesteuert nachziehen (alle vorhandenen deploy-*-vm.sh):
#      der Stand-Marker neben dem Image (Hash flake.lock+Gast-Config, geschrieben
#      vom Deploy) entscheidet — aktuell wird uebersprungen, veraltet wird ohne
#      Gate deployt (--no-start; Revert jederzeit ueber die Chronik, s. README-update-all.md).
#      Laufende VMs werden NIE angefasst — nur gemerkt und am Ende erinnert.
#   4) flake.lock committen (als DU, nicht root; Commit-Body traegt den Paket-Diff)
#   5) Firmware/BIOS via fwupd/LVFS: pruefen -> [j/N]-Gate -> anwenden (Bestaetigung = REBOOT)
#
# Jeder Lauf (ausser --dry-run) wird komplett mitgeschnitten: Session-Log unter
#   ~/.local/state/update-all/<Datum>_<Host>.log  (Retention: die letzten 20 Laeufe)
#
# Aufruf (irgendwo im Repo):  bash update-all.sh [--host-only] [--dry-run]
#   --host-only : nur Flake + Host (inkl. Smoke-Checks); VMs NICHT anfassen und KEINE
#                 Firmware (kein Reboot-Risiko, z. B. waehrend du in der dev-VM arbeitest)
#   --dry-run   : nur zeigen, was es taete; laeuft als einziger Modus auch ohne TTY
#
# Jeder andere Lauf braucht ein interaktives Terminal — die eingreifenden Schritte
# (Host-Aktivierung, Rabby-Bump, Firmware) haben ihr [j/n]-Gate. Die VM-Deploys in
# Abschnitt 3 laufen seit 2026-07-21 bewusst GATE-FREI: der Stand-Marker macht die
# Entscheidung trivial ("Image veraltet + VM aus" -> deployen), und die Chronik
# (git log -- flake.lock) garantiert den Rueckweg auf jeden frueheren Stand.
# ('--yes' 2026-07-12 entfernt: kein Aufrufer, loeste "unbeaufsichtigt" am sudo-Prompt nie
#  ein und haette am BIOS-Reboot in Abschnitt 5 eine gefaehrliche Doppelsemantik gebraucht.)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
DRY_RUN=0; HOST_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --host-only) HOST_ONLY=1 ;;
    --dry-run)   DRY_RUN=1 ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *) printf 'Unbekanntes Argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

info() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then printf '   \033[2m(dry-run)\033[0m %s\n' "$*"; else "$@"; fi; }

# Gates lesen von stdin -> ohne TTY frueh und deutlich scheitern, statt spaeter mitten im
# Lauf an einem sudo ohne Terminal zu stolpern. Einzige Ausnahme: --dry-run liest nichts.
if [ "$DRY_RUN" -eq 0 ] && [ ! -t 0 ]; then
  die "Interaktives Terminal erforderlich — nur --dry-run laeuft ohne TTY."
fi

# ---------------------------------------------------------------------------
# Ins Repo-Wurzelverzeichnis (Skript darf aus jedem Unterordner laufen)
# ---------------------------------------------------------------------------
if [ ! -f flake.nix ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$root" ] && cd "$root"
fi
[ -f flake.nix ] || die "Keine flake.nix gefunden — bitte im Repo (oder Repo-Root) ausfuehren."
command -v nixos-rebuild >/dev/null 2>&1 || die "nixos-rebuild nicht gefunden (kein NixOS-Host?)."

HOST="$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null)"
[ -n "$HOST" ] || die "Hostnamen nicht ermittelbar (weder 'hostname -s' noch /etc/hostname)."
[ -d "hosts/${HOST}" ] || warn "hosts/${HOST} nicht gefunden — ist .#${HOST} der richtige Flake-Output?"
REPO_ROOT="$PWD"

# ---------------------------------------------------------------------------
# Session-Log: kompletter Lauf (Diff, Prompts samt Antworten, VM-Deploys, Firmware,
# vor allem: FEHLER und Abbrueche — der forensisch wichtigste Fall) nach
# ~/.local/state/update-all/. /home liegt AUSSERHALB der NixOS-Generationen: ein
# Rollback (--rollback/Bootmenue) laesst die Logs unangetastet. tee schreibt
# zeilenweise durch -> auch beim Firmware-Reboot (Abschnitt 5) ist das Log bis
# zuletzt vollstaendig. ANSI-Farben bleiben drin (lesen mit: less -R).
# ---------------------------------------------------------------------------
LOGFILE=""; SMOKE_WARN=0; KERNEL_REBOOT=0; DIFF_OUT=""; pre_failed=""; VM_PENDING=""
if [ "$DRY_RUN" -eq 0 ]; then
  LOGDIR="${XDG_STATE_HOME:-$HOME/.local/state}/update-all"
  mkdir -p "$LOGDIR"
  LOGFILE="$LOGDIR/$(date +%Y-%m-%d_%H%M%S)_${HOST}.log"
  exec > >(tee "$LOGFILE") 2>&1
  # Retention: nur die letzten 20 Laeufe behalten (Dateinamen sind selbst erzeugt
  # und newline-frei; find statt ls haelt shellcheck sauber).
  find "$LOGDIR" -maxdepth 1 -name '*.log' -printf '%T@\t%p\n' 2>/dev/null \
    | sort -rn | tail -n +21 | cut -f2- | xargs -r -d '\n' rm -f --
  info "Session-Log: $LOGFILE"
  # Vorzustand festhalten: waren Units schon VOR dem Update kaputt? (leer = nein)
  # -> macht in 2b "neu kaputt" von "war schon kaputt" unterscheidbar.
  pre_failed=$(systemctl --failed --no-legend 2>/dev/null || true)
  if [ -n "$pre_failed" ]; then
    warn "Schon VOR dem Update fehlgeschlagene Units (Einordnung fuer die Smoke-Checks):"
    printf '%s\n' "$pre_failed"
  fi
fi

# setuid-sudo sicherstellen: im Notification-/User-Service-Kontext (Update-Icon,
# "Jetzt aktualisieren"-Knopf aus modules/host-updates.nix) liegt /run/wrappers/bin
# sonst nicht vorn im PATH -> sudo traefe die nicht-setuid-Kopie und bricht ab.
export PATH="/run/wrappers/bin:$PATH"

# Verwaister-Bump-Schutz (Kombi-Loesung mit dem Update-Check in host-updates.nix):
# stirbt das Skript zwischen Bump und erfolgreichem Switch (Strg-C, Fenster zu,
# unerwarteter set-e-Abbruch), wird der flake.lock-Bump verworfen -> kein
# gebumptes-aber-nicht-gebautes flake.lock. Die regulaeren Pfade (Gate-'n',
# Build-/Switch-Fehler) rufen revert_lock selbst und stellen den Trap still.
LOCK_BUMPED=0; UPDATE_DONE=0
cleanup() {
  if [ "$LOCK_BUMPED" -eq 1 ] && [ "$UPDATE_DONE" -eq 0 ]; then
    warn "Abbruch vor Abschluss — verwerfe den flake.lock-Bump."
    git -C "$REPO_ROOT" checkout -- flake.lock 2>/dev/null || true
  fi
}
trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP

# ---------------------------------------------------------------------------
# 0b) Payload-Abgleich — zentrale Dateien aus den Auslieferungs-Repos nachziehen
# ---------------------------------------------------------------------------
# Quellen stehen in payload-sources.conf (eine je Zeile: name=url-oder-pfad[#ref];
# '#' kommentiert; jede Quelle MUSS ein Git-Repo sein — auch lokale Pfade/Spiegel).
# Fehlt die Datei, schlaeft der Abschnitt still (install.sh legt sie auf neuen
# Systemen an; Bestands-Repos aktivieren das Feature durch Anlegen der Datei).
# Je Quelle: Cache-Clone/-Fetch (~/.cache/nixos-config-payloads/<name>) ->
# files/ gegen das Repo diffen -> Diff zeigen -> [J/n]-Gate -> atomar uebernehmen
# (tmp+mv, neuer Inode — dadurch auch fuer das gerade LAUFENDE update-all.sh
# selbst sicher) -> Provenienz-Commit NUR ueber diese Dateien
# ('payload: <name> -> <rev>', Dateiliste im Body; Chronik: git log --grep=payload).
# Schutzgitter: uncommittete lokale Aenderungen an payload-verwalteten Dateien
# blockieren genau DIESE Quelle ("erst committen" — die einzige Stelle, an der
# sonst Arbeit stumm verloren ginge); der restliche Lauf geht immer weiter.
# Offline/Fehler = warnen + weiter (self-guarding). Der Payload LOESCHT NIE.
# Architektur/Kundendoku: docs/README-payload.md · Kommandos: git-cheatsheet §12.
# === PAYLOAD-0B BEGIN ===
PAYLOAD_CONF="payload-sources.conf"

payload_sync_source() {  # $1 = Name, $2 = url-oder-pfad[#ref]
  local name="$1" spec="$2" url ref cache rev rel changed dirty n ans self_updated tmp
  url="${spec%%#*}"; ref=""
  case "$spec" in *"#"*) ref="${spec#*#}" ;; esac
  cache="${XDG_CACHE_HOME:-$HOME/.cache}/nixos-config-payloads/${name}"

  # Holen — jeder Fehlschlag ist ein Skip dieser Quelle, nie ein Abbruch des Laufs
  if [ ! -d "$cache/.git" ]; then
    if ! git clone -q "$url" "$cache" 2>/dev/null; then
      warn "Payload '${name}': Quelle nicht erreichbar (${url}) — uebersprungen."
      return 0
    fi
  fi
  git -C "$cache" fetch -q --tags origin 2>/dev/null \
    || warn "Payload '${name}': fetch fehlgeschlagen (offline?) — nutze letzten Cache-Stand."
  if [ -n "$ref" ]; then
    git -C "$cache" checkout -q --detach "origin/${ref}" 2>/dev/null \
      || git -C "$cache" checkout -q --detach "$ref" 2>/dev/null \
      || { warn "Payload '${name}': Ref '${ref}' nicht gefunden — uebersprungen."; return 0; }
  else
    git -C "$cache" checkout -q --detach origin/HEAD 2>/dev/null \
      || git -C "$cache" checkout -q --detach HEAD 2>/dev/null || true
  fi
  rev="$(git -C "$cache" rev-parse --short HEAD 2>/dev/null || echo '?')"
  if [ ! -d "$cache/files" ]; then
    warn "Payload '${name}': kein files/-Verzeichnis in der Quelle — uebersprungen."
    return 0
  fi

  # Vergleich: welche Dateien weichen ab (oder fehlen lokal)?
  changed=""
  while IFS= read -r rel; do
    rel="${rel#./}"
    cmp -s "$cache/files/$rel" "$rel" 2>/dev/null || changed="${changed}${rel}"$'\n'
  done < <(cd "$cache/files" && find . -type f | sort)
  if [ -z "$changed" ]; then
    ok "Payload '${name}': bereits auf Stand ${rev}."
    return 0
  fi

  # Dirty-Schutzgitter — ausschliesslich ueber die payload-verwalteten Pfade DIESER Quelle
  dirty=""
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if [ -e "$rel" ] && [ -n "$(git status --porcelain -- "$rel" 2>/dev/null)" ]; then
      dirty="${dirty}  ${rel}"$'\n'
    fi
  done <<< "$changed"
  if [ -n "$dirty" ]; then
    warn "Payload '${name}': uncommittete Aenderungen an payload-verwalteten Dateien:"
    printf '%s' "$dirty"
    warn "Erst committen (bewusste Abweichung, s. git-cheatsheet §12) oder verwerfen (git restore) — Quelle uebersprungen."
    return 0
  fi

  # Diff zeigen, dann das Gate
  n="$(printf '%s' "$changed" | grep -c . || true)"
  info "Payload '${name}' → ${rev}: ${n} Datei(en) weichen ab:"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    diff -u --label "repo/${rel}" --label "${name}/${rel}" "$rel" "$cache/files/$rel" 2>/dev/null || true
  done <<< "$changed"
  if [ "$DRY_RUN" -eq 1 ]; then
    info "(dry-run) Uebernahme + Commit uebersprungen."
    return 0
  fi
  read -rp "$(printf '\033[1;34m[?]\033[0m Payload %s auf %s uebernehmen? [J/n]: ' "$name" "$rev")" ans || ans=""
  case "$ans" in
    n|N) info "Payload '${name}': nicht uebernommen — der naechste Lauf fragt erneut."; return 0 ;;
  esac

  # Uebernehmen: atomar via tmp+mv (neuer Inode — ein laufendes update-all.sh liest
  # ungestoert seine alte Datei weiter; in-place-Kopie wuerde es korrumpieren)
  self_updated=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    mkdir -p "$(dirname "$rel")"
    tmp="${rel}.payload-new.$$"
    cp "$cache/files/$rel" "$tmp"
    if [ -x "$cache/files/$rel" ]; then chmod 0755 "$tmp"; else chmod 0644 "$tmp"; fi
    mv -f "$tmp" "$rel"
    git add -- "$rel" 2>/dev/null || true
    if [ "$rel" = "update-all.sh" ]; then self_updated=1; fi
  done <<< "$changed"
  if git commit -q -m "payload: ${name} → ${rev}" -m "$(printf 'Uebernommene Dateien:\n%s' "$changed")" 2>/dev/null; then
    ok "Payload '${name}': uebernommen + committet (payload: ${name} → ${rev})."
  else
    warn "Payload '${name}': Commit fehlgeschlagen (git-Identitaet gesetzt?) — Dateien liegen uebernommen im Arbeitsbaum."
  fi

  # Selbst-Update: Neustart anbieten, damit der restliche Lauf die frische Logik nutzt
  if [ "$self_updated" -eq 1 ]; then
    warn "update-all.sh wurde durch diesen Payload aktualisiert."
    read -rp "$(printf '\033[1;34m[?]\033[0m Lauf mit der frischen Version neu starten? [J/n]: ')" ans || ans=""
    case "$ans" in
      n|N) info "Weiter mit der bereits laufenden alten Version (die Datei selbst ist neu)." ;;
      *)   info "Neustart mit frischer Version …"
           if [ "$HOST_ONLY" -eq 1 ]; then exec bash "$0" --host-only; else exec bash "$0"; fi ;;
    esac
  fi
  return 0
}

if [ -f "$PAYLOAD_CONF" ]; then
  while IFS= read -r pl_line <&3 || [ -n "$pl_line" ]; do
    case "$pl_line" in ''|'#'*) continue ;; esac
    pl_name="${pl_line%%=*}"; pl_spec="${pl_line#*=}"
    if [ -z "$pl_name" ] || [ "$pl_spec" = "$pl_line" ] || [ -z "$pl_spec" ]; then
      warn "payload-sources.conf: Zeile ohne gueltiges 'name=quelle' uebersprungen: ${pl_line}"
      continue
    fi
    case "$pl_name" in
      *[!A-Za-z0-9_-]*) warn "payload-sources.conf: ungueltiger Quellen-Name uebersprungen: ${pl_name}"; continue ;;
    esac
    payload_sync_source "$pl_name" "$pl_spec"
  done 3< "$PAYLOAD_CONF"
fi
# === PAYLOAD-0B END ===

# ---------------------------------------------------------------------------
# 1) Flake-Inputs bumpen
# ---------------------------------------------------------------------------
info "Aktualisiere Flake-Inputs (nix flake update)…"
run nix flake update
if [ "$DRY_RUN" -eq 0 ]; then LOCK_BUMPED=1; fi

# Transparenz: zeigen, was sich am Lock geaendert hat.
if [ "$DRY_RUN" -eq 0 ]; then
  if [ -n "$(git status --porcelain -- flake.lock 2>/dev/null)" ]; then
    info "Aenderungen an flake.lock:"
    git --no-pager diff --stat -- flake.lock || true
  else
    ok "flake.lock unveraendert — Inputs schon aktuell."
  fi
fi

# ---------------------------------------------------------------------------
# 2) Host: erst BAUEN (unprivilegiert, ohne Aktivierung) -> Paket-Diff -> aktivieren
#    'nixos-rebuild build' legt ./result an (gitignored) und braucht KEIN sudo — das
#    Passwort kommt erst bei der Aktivierung. So sind die realen Paketaenderungen
#    VOR dem Umschalten sichtbar, und ein Abbruch ist folgenlos.
#    Abbruch ('n') oder Fehler verwirft den flake.lock-Bump -> Repo bleibt == laufendes
#    System (kein Drift); der naechste Lauf holt ohnehin einen frischen Bump.
#    Diff-Werkzeug: nvd, wenn vorhanden (kommt via host-updates.nix; gruppierte
#    Ausgabe, ausgerichtete Versionsspruenge, Summenzeile) — sonst eingebautes
#    'nix store diff-closures', damit das Skript auch auf Hosts ohne das Modul
#    lauffaehig bleibt. Der Diff wird mitgeschnitten und in Abschnitt 4 in den
#    flake.lock-Commit-Body gelegt (git log = Update-Chronik, offsite nach push).
#    (VMs bewusst ohne Diff: near-stateless -> kein sinnvoller Vorzustand ohne Statefile.)
# ---------------------------------------------------------------------------
revert_lock() {  # flake.lock auf den committeten Stand zuruecksetzen (kein Drift)
  if git checkout -- flake.lock 2>/dev/null; then
    ok "flake.lock auf den committeten Stand zurueckgesetzt — kein Drift."
  else
    warn "flake.lock nicht zurueckgesetzt (nicht getrackt?) — bitte manuell pruefen."
  fi
  LOCK_BUMPED=0   # Trap still: der Bump ist behandelt
}

if [ "$DRY_RUN" -eq 1 ]; then
  info "(dry-run) Wuerde Host bauen (nixos-rebuild build), Closure-Diff zeigen, dann aktivieren."
else
  info "Baue neues Host-System (ohne Aktivierung; sudo folgt erst bei der Aktivierung)…"
  if ! nixos-rebuild build --flake ".#${HOST}"; then
    warn "Host-Build fehlgeschlagen — verwerfe den flake.lock-Bump."
    revert_lock
    die "Abbruch: Host-Build fehlgeschlagen (System und Repo unveraendert)."
  fi

  if [ "$(readlink -f /run/current-system)" = "$(readlink -f ./result)" ]; then
    ok "Host-Closure unveraendert — keine Paketaenderungen (nur Input-Bump im Lock)."
    DIFF_OUT="(Closure unveraendert — keine Paketaenderungen, nur Input-Bump im Lock.)"
  else
    info "Paketaenderungen am Host (aktiv -> neu):"
    # Capture statt Direktausgabe: derselbe Text geht 1:1 in den Commit-Body (Abschnitt 4)
    # und ins Session-Log. Nebeneffekt gewollt: kein TTY fuer das Diff-Tool -> farbfreier,
    # sauber archivierbarer Text.
    if command -v nvd >/dev/null 2>&1; then
      DIFF_OUT=$(nvd diff /run/current-system ./result 2>&1 || true)
    else
      DIFF_OUT=$(nix store diff-closures /run/current-system ./result 2>&1 || true)
    fi
    printf '%s\n' "$DIFF_OUT"

    # Proceed-Gate (TTY ist oben garantiert). Bei 'n': Lock verwerfen, NICHT aktivieren.
    read -rp "$(printf '\033[1;34m[?]\033[0m Host jetzt auf diesen Stand aktivieren? [J/n]: ')" ans || ans=""
    case "$ans" in
      [nN]*)
        warn "Aktivierung abgebrochen — verwerfe den flake.lock-Bump."
        revert_lock
        exit 0
        ;;
    esac
  fi
fi

info "Aktiviere Host: sudo nixos-rebuild switch --flake .#${HOST}…"
if ! run sudo nixos-rebuild switch --flake ".#${HOST}"; then
  warn "Aktivierung fehlgeschlagen — verwerfe den flake.lock-Bump."
  revert_lock
  die "Abbruch: 'nixos-rebuild switch' fehlgeschlagen."
fi
ok "Host aktualisiert."
UPDATE_DONE=1   # ab hier ist der Bump gebaut -> Trap darf ihn nicht mehr verwerfen
# (./result bleibt liegen — gitignored; der naechste Build/VM-Deploy ueberschreibt es.)

# ---------------------------------------------------------------------------
# 2b) Smoke-Checks — direkt nach der Aktivierung, bewusst VOR den VM-Gates: ist
#     libvirt oder die vfio-Bindung nach einem Kernel-Update gerissen, soll das als
#     klare Warnung auf dem Tisch liegen, BEVOR an den VM-Gates entschieden wird
#     (sonst aeussert es sich erst als verwirrender Deploy-Fehler in Abschnitt 3).
#     Semantik: WARNEN, nie abbrechen, Exit bleibt 0 — der Host ist bereits aktiv,
#     Rollback ist eine bewusste Entscheidung (Hinweis kommt am Skriptende).
#     Host-Spezifisches liegt als check-*.sh im Repo-Root (Discovery wie bei den
#     deploy-*-vm.sh); jeder Check ist selbst-guardend: nicht zustaendig -> still
#     Exit 0, Warnung -> Exit 1. install.sh liefert bewusst KEINE Checks mit.
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ]; then
  info "Smoke-Checks (Host-Zustand nach der Aktivierung)…"
  # Erst die Aktivierungs-Jobs leerlaufen lassen — sofort gemessen waeren noch
  # startende Services falsche Treffer. 'running' = sauber; alles andere
  # (degraded, Timeout) -> fehlgeschlagene Units zeigen.
  state=$(timeout 90 systemctl is-system-running --wait 2>/dev/null || true)
  if [ "$state" = "running" ]; then
    ok "systemd: running — keine fehlgeschlagenen Units."
  else
    SMOKE_WARN=1
    warn "systemd meldet '${state:-Timeout nach 90 s}' — fehlgeschlagene Units:"
    systemctl --failed --no-legend || true
    [ -n "$pre_failed" ] && warn "(Vorzustand am Log-Anfang — nicht alles davon muss neu sein.)"
  fi
  for chk in ./check-*.sh; do
    [ -e "$chk" ] || continue        # kein Treffer -> Glob bleibt literal
    if bash "$chk"; then
      : # Check meldet OK/Nichtzustaendigkeit selbst
    else
      SMOKE_WARN=1
      warn "Smoke-Check meldet Probleme: ${chk#./}"
    fi
  done
  [ "$SMOKE_WARN" -eq 0 ] && ok "Smoke-Checks unauffaellig."

  # Kernel-Update erkennen (BSI SYS.2.3.A4): NixOS aktiviert einen neuen Kernel
  # erst beim Reboot — bis dahin laeuft der alte weiter (inkl. seiner Luecken).
  # Vergleich gebooteter vs. konfigurierter Kernel; bewusst nur WARNEN, kein
  # Zwangs-Reboot (konservativ — die Erinnerung kommt gebuendelt am Skriptende).
  booted_kernel=$(readlink -f /run/booted-system/kernel 2>/dev/null || true)
  current_kernel=$(readlink -f /run/current-system/kernel 2>/dev/null || true)
  if [ -n "$booted_kernel" ] && [ -n "$current_kernel" ] \
     && [ "$booted_kernel" != "$current_kernel" ]; then
    KERNEL_REBOOT=1
    warn "Kernel aktualisiert — das System laeuft noch auf dem ALTEN Kernel (aktiv erst nach Reboot)."
  fi
fi

# ---------------------------------------------------------------------------
# 2c) Rabby-Wallet-Pin (browser-vm): Upstream-Check + Bump-Gate
# ---------------------------------------------------------------------------
# Die Rabby-Extension ist BEWUSST gepinnt (Version + Hash in der Gast-Config) —
# "ein Wallet-Update ist eine bewusste Commit-Entscheidung, kein stiller
# Store-Push" (Begruendung: Kopf von hosts/browser-vm/configuration.nix).
# Dieser Abschnitt automatisiert nur die MECHANIK, nicht die Entscheidung:
# gepinnte vs. neueste GitHub-Release anzeigen, Release-Notes-Link davor,
# Gate mit Default NEIN. Erst nach 'j': Hash via 'nix store prefetch-file'
# (laedt nur das Zip, kein Image-Build), Version+Hash per sed ersetzen,
# EIGENER Commit. Das frische Image baut anschliessend Abschnitt 3 von
# selbst — die Config-Aenderung laesst den Stand-Marker abweichen.
# Selbst-guardend: offline/API-Fehler/kein Pin -> Hinweis + weiter im Lauf.
RABBY_CFG="hosts/browser-vm/configuration.nix"
if [ "$HOST_ONLY" -eq 1 ]; then
  info "--host-only: Rabby-Versionscheck uebersprungen."
elif [ "$DRY_RUN" -eq 1 ]; then
  info "(dry-run) Wuerde die gepinnte Rabby-Version gegen die neueste GitHub-Release pruefen."
elif [ ! -f "$RABBY_CFG" ]; then
  info "Keine browser-vm-Gast-Config — Rabby-Versionscheck uebersprungen."
elif ! command -v curl >/dev/null 2>&1; then
  info "curl nicht vorhanden — Rabby-Versionscheck uebersprungen."
else
  rabby_pinned=$(sed -n 's/^ *rabbyVersion = "\([^"]*\)".*/\1/p' "$RABBY_CFG" | head -n1)
  rabby_latest=$(curl -fsSL -m 10 -H 'Accept: application/vnd.github+json' \
                   https://api.github.com/repos/RabbyHub/Rabby/releases/latest 2>/dev/null \
                 | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n1)
  if [ -z "$rabby_pinned" ]; then
    info "Kein rabbyVersion-Pin in ${RABBY_CFG} — Check uebersprungen."
  elif [ -z "$rabby_latest" ]; then
    warn "Rabby-Versionscheck: GitHub-API nicht erreichbar (offline/Rate-Limit?) — uebersprungen."
  elif [ "$rabby_pinned" = "$rabby_latest" ]; then
    ok "Rabby-Pin aktuell (v${rabby_pinned})."
  else
    warn "Rabby: gepinnt v${rabby_pinned} — neueste Release v${rabby_latest}."
    info "VOR dem Bestaetigen Release Notes pruefen:"
    info "  https://github.com/RabbyHub/Rabby/releases/tag/v${rabby_latest}"
    read -rp "$(printf '\033[1;34m[?]\033[0m Rabby-Pin jetzt auf v%s heben (Wallet-Update!)? [j/N]: ' "$rabby_latest")" ans || ans=""
    case "$ans" in
      [jJyY]*)
        rabby_url="https://github.com/RabbyHub/Rabby/releases/download/v${rabby_latest}/Rabby_v${rabby_latest}.zip"
        info "Ermittle Hash (laedt nur das Zip): nix store prefetch-file ${rabby_url}"
        rabby_hash=$(nix store prefetch-file --json "$rabby_url" 2>/dev/null \
                     | sed -n 's/.*"hash": *"\(sha256-[^"]*\)".*/\1/p' | head -n1)
        # Guards: Hash muss da sein und die Config genau EIN Versions- und EIN
        # sha256-Pin-Muster tragen — sonst nichts blind editieren, sondern auf
        # den dokumentierten manuellen Weg verweisen (troubleshooting.md, D).
        if [ -z "$rabby_hash" ]; then
          warn "Hash nicht ermittelbar (Download fehlgeschlagen?) — Bump uebersprungen."
          warn "Manuell: rabbyVersion bumpen, hash = lib.fakeHash, deployen (Build nennt den Hash)."
        elif [ "$(grep -c 'rabbyVersion = "' "$RABBY_CFG")" -ne 1 ] \
          || [ "$(grep -c 'hash = "sha256-' "$RABBY_CFG")" -ne 1 ]; then
          warn "Pin-Muster in ${RABBY_CFG} nicht eindeutig — Bump uebersprungen (manuell editieren)."
        else
          sed -i "s|rabbyVersion = \"${rabby_pinned}\"|rabbyVersion = \"${rabby_latest}\"|" "$RABBY_CFG"
          sed -i "s|hash = \"sha256-[^\"]*\"|hash = \"${rabby_hash}\"|" "$RABBY_CFG"
          if git commit -m "browser-vm: rabby ${rabby_pinned} -> ${rabby_latest}" \
                        -m "Release: https://github.com/RabbyHub/Rabby/releases/tag/v${rabby_latest}" \
                        -m "Hash via nix store prefetch-file; bestaetigt im update-all-Gate (2c)." \
                        -- "$RABBY_CFG"; then
            ok "Rabby-Pin auf v${rabby_latest} gehoben + committet — das frische Image baut Abschnitt 3."
          else
            warn "Commit des Rabby-Bumps fehlgeschlagen — Aenderung liegt uncommittet im Arbeitsbaum."
          fi
        fi
        ;;
      *) info "Rabby-Bump uebersprungen — der naechste Lauf erinnert erneut." ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# 3) VM-Images Stand-gesteuert nachziehen — ueber die vorhandenen deploy-*-vm.sh
#    (aktuell dev-vm + browser-vm; ein kuenftiges deploy-ai-vm.sh laeuft automatisch mit)
# ---------------------------------------------------------------------------
# GATE-FREI seit 2026-07-21 (Begruendung: README-update-all.md): der Stand-Marker
# neben dem Image (geschrieben vom Deploy; Formel = Hash ueber flake.lock +
# Gast-Config, GESPIEGELT in beiden deploy-*-vm.sh) macht die Frage trivial —
# identisch: Image nachweislich aktuell -> ueberspringen; abweichend/fehlend:
# Rebuild faellig. Deployt wird NUR, wenn die VM aus ist, und mit --no-start
# (on-demand-Prinzip: sie war aus, sie bleibt aus). LAUFENDE VMs werden nie
# angefasst — Zed-Session/Keystone-Signing duerfen nicht abreissen; stattdessen
# Sammel-Hinweis am Skriptende, und der Marker erinnert bei jedem Folgelauf.
# Rueckweg bei Bedarf: alten flake.lock-Stand aus der Chronik auschecken und
# gezielt deployen (VM-Images haben keine Generationen).
if [ "$HOST_ONLY" -eq 1 ]; then
  info "--host-only: VMs werden nicht angefasst."
else
  shopt -s nullglob
  vm_scripts=( deploy-*-vm.sh )
  shopt -u nullglob
  if [ "${#vm_scripts[@]}" -eq 0 ]; then
    info "Keine deploy-*-vm.sh gefunden — keine VMs zu aktualisieren."
  else
    info "Gefundene VM-Deploy-Skripte: ${vm_scripts[*]}"
    for vmscript in "${vm_scripts[@]}"; do
      vm="${vmscript#deploy-}"; vm="${vm%.sh}"   # deploy-dev-vm.sh -> dev-vm
      if [ "$DRY_RUN" -eq 1 ]; then
        info "(dry-run) ${vm}: wuerde Stand-Marker vergleichen und bei Abweichung deployen (bash ${vmscript} --no-start)."
        continue
      fi
      vm_cfg="hosts/${vm}/configuration.nix"
      if [ ! -f "$vm_cfg" ]; then
        warn "${vm}: Gast-Config ${vm_cfg} fehlt — uebersprungen (Marker nicht bestimmbar)."
        continue
      fi
      # Soll-Stand nach der Marker-Formel (Spiegel: deploy-*-vm.sh).
      vm_state=$(cat flake.lock "$vm_cfg" | sha256sum | cut -d' ' -f1)
      vm_marker=$(cat "/var/lib/libvirt/images/${vm}.flake-rev" 2>/dev/null || true)
      if [ "$vm_marker" = "$vm_state" ]; then
        ok "${vm}: Image aktuell (Stand-Marker identisch) — kein Rebuild noetig."
        continue
      fi
      if command -v virsh >/dev/null 2>&1 \
         && sudo virsh domstate "$vm" 2>/dev/null | grep -q running; then
        warn "${vm}: Rebuild faellig, aber die VM LAEUFT — wird nicht angefasst (Sammel-Hinweis am Ende)."
        VM_PENDING="${VM_PENDING}  bash ${vmscript}    # ${vm} lief waehrend des Updates
"
        continue
      fi
      if [ -n "$vm_marker" ]; then vm_reason="abweichend"; else vm_reason="fehlt (Erstlauf?)"; fi
      info "${vm}: Rebuild faellig (Stand-Marker ${vm_reason}) — deploye (bash ${vmscript} --no-start)…"
      if bash "$vmscript" --no-start; then
        ok "${vm} aktualisiert (bleibt aus — der naechste Icon-Start bootet und verifiziert das frische Image)."
      else
        warn "${vm}: Deploy FEHLGESCHLAGEN — Host-Update bleibt aktiv (Sammel-Hinweis am Ende)."
        VM_PENDING="${VM_PENDING}  bash ${vmscript}    # ${vm}: Deploy fehlgeschlagen
"
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# 4) flake.lock committen — als DU (nicht root), damit das Repo dir gehoert
# ---------------------------------------------------------------------------
if [ "$DRY_RUN" -eq 0 ] && [ -n "$(git status --porcelain -- flake.lock 2>/dev/null)" ]; then
  info "Committe flake.lock…"
  git add flake.lock
  # Commit-Body traegt den Paket-Diff -> 'git log -- flake.lock' wird zur Update-Chronik,
  # nach 'git push' auch offsite lesbar (Maschine tot -> von jedem Geraet nachschlagbar).
  # Hostname in Betreff UND Body: der Diff ist HOST-spezifisch, das Repo kann
  # mehrere Hosts tragen. Fehlgeschlagene Laeufe committen nie -> dafuer ist das Session-Log da.
  if git commit -m "update: flake.lock $(date +%Y-%m-%d) (${HOST})" \
                -m "Paket-Diff auf ${HOST}:" \
                -m "${DIFF_OUT:-(kein Diff erfasst)}" -- flake.lock; then
    ok "flake.lock committet (Paket-Diff im Commit-Body). Mit 'git push' wird die Chronik offsite lesbar."
  else
    warn "Commit uebersprungen."
  fi
elif [ "$DRY_RUN" -eq 0 ]; then
  info "Kein flake.lock-Diff zu committen."
fi

# ---------------------------------------------------------------------------
# 5) Firmware/BIOS via fwupd (LVFS) — BEWUSST der letzte Abschnitt: ein mit 'j'
#    bestaetigtes Update rebootet die Maschine direkt ('fwupdmgr update -y' bejaht
#    auch die Neustart-Frage). Ab hier ist nichts mehr offen — Host aktiv, VMs
#    behandelt, flake.lock committet — der Reboot kann nichts Halbfertiges abreissen.
#    Ohne fwupd (host-updates.nix nicht importiert): still ueberspringen. Mit
#    --host-only: ueberspringen (ein BIOS-Reboot wuerde laufende VMs beenden —
#    genau die Situation, fuer die --host-only da ist). LVFS hinkt Dell gelegentlich
#    eine Version hinterher — bei Security-BIOS Gegencheck auf der Hersteller-Seite.
# ---------------------------------------------------------------------------
if [ "$HOST_ONLY" -eq 1 ]; then
  info "--host-only: Firmware-Abschnitt uebersprungen (BIOS-Reboot wuerde laufende VMs beenden)."
elif ! command -v fwupdmgr >/dev/null 2>&1; then
  info "fwupdmgr nicht vorhanden — Firmware-Abschnitt uebersprungen."
elif [ "$DRY_RUN" -eq 1 ]; then
  info "(dry-run) Wuerde LVFS-Metadaten auffrischen (fwupdmgr refresh) und Updates anzeigen."
else
  info "Pruefe Firmware-Updates (fwupd/LVFS)…"
  fwupdmgr refresh --force >/dev/null 2>&1 \
    || warn "LVFS-Refresh fehlgeschlagen (offline?) — pruefe mit lokalen Metadaten weiter."
  if updates=$(fwupdmgr get-updates 2>/dev/null); then
    printf '%s\n' "$updates"
    warn "Bestaetigen wendet die Firmware JETZT an — ein BIOS-Update startet den Rechner"
    warn "direkt neu. Offene Arbeit sichern; laufende VMs werden dabei hart beendet."
    read -rp "$(printf '\033[1;34m[?]\033[0m Firmware jetzt anwenden? [j/N]: ')" ans || ans=""
    case "$ans" in
      [jJyY]*)
        # sudo statt Polkit: laeuft auch in SSH-Sitzungen ohne Desktop-Polkit-Agent;
        # der sudo-Timestamp ist vom switch (Abschnitt 2) meist ohnehin noch warm.
        # ERSTLAUF BEOBACHTEN: exaktes Prompt-/Reboot-Verhalten von '-y' der
        # installierten fwupd-Version verifizieren (siehe troubleshooting.md, D).
        sudo fwupdmgr update -y \
          || warn "Firmware-Update fehlgeschlagen/abgebrochen — spaeter: sudo fwupdmgr update"
        ;;
      *) info "Firmware uebersprungen — spaeter manuell: sudo fwupdmgr update" ;;
    esac
  else
    ok "Keine Firmware-Updates gemeldet."
  fi
fi

# Abschluss: Smoke-Warnungen prominent buendeln — die Einzelheiten stehen weiter oben
# und im Session-Log; hier nur die Handlungsoptionen.
if [ "$SMOKE_WARN" -eq 1 ]; then
  warn "Mindestens ein Smoke-Check hat gewarnt — Details oben bzw. im Session-Log."
  warn "Rollback bei Bedarf: sudo nixos-rebuild switch --rollback   (oder Bootmenue-Eintrag)."
fi
if [ -n "$VM_PENDING" ]; then
  warn "VM-Images noch auf altem Stand — nachholen (jeder weitere update-all-Lauf erinnert ebenfalls):"
  printf '%s' "$VM_PENDING"
fi
if [ "$KERNEL_REBOOT" -eq 1 ]; then
  warn "Reboot ausstehend: der neue Kernel laeuft erst nach einem Neustart (SYS.2.3.A4 —"
  warn "zeitnah rebooten; bis dahin ist der Host auf dem alten Kernel-Stand unterwegs)."
fi
[ -n "$LOGFILE" ] && info "Session-Log dieses Laufs: $LOGFILE"
ok "update-all fertig."
