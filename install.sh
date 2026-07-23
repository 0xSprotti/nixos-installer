#!/usr/bin/env bash
#
# Generischer NixOS-First-Boot-Installer.
# Fragt Hostname/Benutzer/Tastatur ab, erkennt die Zielplatte, erzeugt das
# Config-Repo unter ~/nixos-config und installiert. Keine persoenlichen Daten im Skript.
#
# WICHTIG: install.sh reist mit dem Installer-Repo — der files/-Payload daneben
# (Module, update-all.sh, Doku, flake.nix) IST die Basis des erzeugten Repos.
# Deshalb das Repo KOMPLETT klonen und daraus starten; ein Einzeldatei-Download
# bricht frueh mit klarer Meldung ab.
#
# Pruef-Lauf (nur Dateien erzeugen, nichts loeschen):
#   bash install.sh --dry-run
# Echter Lauf:
#   bash install.sh
# (Das Skript holt fehlende Tools - git/mkpasswd/pciutils - selbst via nix-shell.)
#
set -euo pipefail

# ── Schutzgitter: files/-Payload muss neben install.sh liegen (Repo-Klon!) ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$SCRIPT_DIR/files/flake.nix" ] \
   || [ ! -f "$SCRIPT_DIR/files/modules/hardening.nix" ] \
   || [ ! -f "$SCRIPT_DIR/files/update-all.sh" ]; then
  echo "FEHLER: files/-Payload fehlt neben install.sh." >&2
  echo "        install.sh ist KEIN Einzeldatei-Download — bitte das Installer-Repo" >&2
  echo "        komplett klonen (git clone <repo-url>) und 'bash install.sh' daraus starten." >&2
  exit 1
fi

# Selbst-Bootstrap: fehlen git/mkpasswd/pciutils, einmal in einer nix-shell mit
# diesen Tools neu starten. So genuegt der Aufruf:  bash install.sh [--dry-run]
if [ -z "${INSTALLER_BOOTSTRAPPED:-}" ] \
   && { ! command -v git >/dev/null 2>&1 || ! command -v mkpasswd >/dev/null 2>&1 || ! command -v lspci >/dev/null 2>&1; }; then
  echo "==> Hole Tools (git mkpasswd pciutils) via nix-shell und starte neu ..."
  exec nix-shell -p git mkpasswd pciutils --run "INSTALLER_BOOTSTRAPPED=1 exec bash $(printf '%q ' "$0" "$@")"
fi

usage() {
  cat <<'USAGE'
install.sh - generischer NixOS-First-Boot-Installer

  bash install.sh [--dry-run]

  --dry-run, -n   nur die Config-Dateien unter ~/nixos-config erzeugen,
                  nichts partitionieren / loeschen / installieren
  --help, -h      diese Hilfe

Sicherheit: Der Installer laeuft nur vom Live-ISO (dort ist "/" ein 'overlay'). Auf einem
installierten System bricht er ab, damit ein versehentlicher Lauf nichts zerstoert.
Bewusster Override fuer Sonderfaelle:  ALLOW_NONLIVE=1 bash install.sh
(dann folgt vor dem Loeschen eine getippte Bestaetigung der Ziel-Platte).

Das Skript holt fehlende Tools (git, mkpasswd, pciutils) selbst via nix-shell.
USAGE
}

DRY_RUN="${DRY_RUN:-0}"   # auch per Umgebungsvariable setzbar (Fallback)
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unbekannte Option: $1 (siehe --help)" >&2; exit 1 ;;
  esac
  shift
done

# Flakes auch waehrend der Installation aktiv (falls im Live-System nicht default)
export NIX_CONFIG="extra-experimental-features = nix-command flakes"

# ===================== 0. Preflight =====================
for t in lsblk lspci git mkpasswd; do
  command -v "$t" >/dev/null 2>&1 || { echo "FEHLER: '$t' fehlt (nix-shell-Bootstrap nicht erfolgt?)." >&2; exit 1; }
done
if [ "$DRY_RUN" != "1" ]; then
  [ -d /sys/firmware/efi ] || { echo "FEHLER: nicht im UEFI-Modus gebootet (systemd-boot braucht UEFI; im BIOS auf UEFI umstellen)." >&2; exit 1; }
  timeout 5 bash -c ': < /dev/tcp/cache.nixos.org/443' 2>/dev/null || { echo "FEHLER: keine Netzverbindung zu cache.nixos.org:443. Erst Netz herstellen (LAN oder nmtui)." >&2; exit 1; }
fi

# ===================== 0b. Schutz: nur vom Live-Installer, nicht auf installiertem System =====================
# Der Installer formatiert Platten (disko destroy,format). Ein versehentlicher Lauf auf einem
# bereits installierten System wuerde es ZERSTOEREN. Auf dem NixOS-Installer-ISO ist "/" ein
# 'overlay'; ein echtes On-Disk-Dateisystem deutet auf ein installiertes System hin -> abbrechen.
# (Dry-Run ist ungefaehrlich und laeuft ueberall — daher nur im Echtlauf pruefen.)
NONLIVE=0
if [ "$DRY_RUN" != "1" ]; then
  ROOT_FSTYPE="$(findmnt -nro FSTYPE / 2>/dev/null | head -n1 || true)"
  case "$ROOT_FSTYPE" in
    ext2|ext3|ext4|btrfs|xfs|f2fs|zfs|reiserfs|jfs)
      if [ "${ALLOW_NONLIVE:-0}" = "1" ]; then
        NONLIVE=1
        echo "WARN: Root-Dateisystem ist '$ROOT_FSTYPE' (kein Live-Overlay) — Override ALLOW_NONLIVE=1 aktiv." >&2
        echo "      Die Ziel-Platte wird gleich VOLLSTAENDIG GELOESCHT; getippte Bestaetigung folgt." >&2
      else
        echo "FEHLER: Root-Dateisystem ist '$ROOT_FSTYPE' — das sieht nach einem INSTALLIERTEN System aus," >&2
        echo "        nicht nach dem Live-Installer (dort ist / ein 'overlay')." >&2
        echo "        Dieser Installer LOESCHT Platten und darf nur vom NixOS-Installer-ISO laufen." >&2
        echo "        -> Vom ISO booten und erneut starten." >&2
        echo "        (Bewusster Override nur fuer Sonderfaelle:  ALLOW_NONLIVE=1 bash install.sh)" >&2
        exit 1
      fi
      ;;
  esac
fi

# ===================== 0c. dGPU fuer D3cold erkennen (vendor-unabhaengig ueber _PR3) =====================
# Eine dedizierte GPU faellt nur dann per vfio-pci in echtes D3cold (Slot stromlos), wenn ihr
# PCIe-Parent-Port eine ACPI-_PR3-Power-Resource hat. Genau danach suchen wir -> trifft die
# D3cold-faehige dGPU treffsicher, ohne nach Hersteller zu raten (im Live-ISO sind ACPI + sysfs da).
# Ergebnis: DGPU_GPU_ID / DGPU_AUDIO_ID / DGPU_VENDOR / DGPU_ADDR (leer, wenn nichts Passendes da).
DGPU_GPU_ID=""; DGPU_AUDIO_ID=""; DGPU_VENDOR=""; DGPU_ADDR=""
for _gpu in $(lspci -Dn 2>/dev/null | awk '$2 ~ /^030[02]/ {print $1}'); do
  # Die primaere Display-GPU (boot_vga=1, i.d.R. die iGPU) NIEMALS anfassen -> sonst Desktop tot.
  [ "$(cat "/sys/bus/pci/devices/$_gpu/boot_vga" 2>/dev/null || echo 0)" = "1" ] && continue
  # Parent-Port ermitteln und absichern, dass es wirklich ein PCI-Device ist (kein "."-Artefakt).
  _par="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$_gpu" 2>/dev/null)")" 2>/dev/null)"
  [ -n "$_par" ] && [ -d "/sys/bus/pci/devices/$_par" ] || continue
  # _PR3 am Parent-Port (sysfs-Name: power_resources_D3hot) = D3cold ueber die Plattform moeglich.
  if [ -e "/sys/bus/pci/devices/$_par/firmware_node/power_resources_D3hot" ]; then
    DGPU_ADDR="$_gpu"
    DGPU_GPU_ID="$(lspci -Dn -s "$_gpu" | awk '{print $3}')"     # vendor:device der GPU-Funktion
    DGPU_VENDOR="${DGPU_GPU_ID%%:*}"
    _bd="${_gpu%.*}"                                             # Bus:Device ohne .Funktion
    # Audio-Funktion an derselben Bus:Device-Adresse (Klasse 0403) -> muss mit durchgereicht werden,
    # sonst haelt sie den Slot ueber D3hot fest.
    DGPU_AUDIO_ID="$(lspci -Dn 2>/dev/null | awk -v bd="$_bd" 'index($1, bd".")==1 && $2 ~ /^0403/ {print $3; exit}')"
    break
  fi
done

# ===================== 1. Abfragen =====================
read -rp "Hostname [nixos]: " HOST;      HOST="${HOST:-nixos}"
read -rp "Benutzername [user]: " USER_;  USER_="${USER_:-user}"
read -rp "Zeitzone [Europe/Berlin]: " TZ; TZ="${TZ:-Europe/Berlin}"
read -rp "Locale [de_DE.UTF-8]: " LOC;    LOC="${LOC:-de_DE.UTF-8}"

echo
echo "Tastaturlayout (xkb):"
echo "  1) de            (Deutsch)"
echo "  2) us            (Englisch US)"
echo "  3) gb            (Englisch UK)"
echo "  4) de,us         (Deutsch + Englisch-US, umschaltbar mit Alt+Shift)"
echo "  5) de,gb         (Deutsch + Englisch-UK, umschaltbar mit Alt+Shift)"
echo "  6) eigene        (kommagetrennte xkb-Codes, z.B. de,us,fr)"
read -rp "Auswahl [1]: " KB; KB="${KB:-1}"
case "$KB" in
  1) XKB="de" ;;  2) XKB="us" ;;  3) XKB="gb" ;;
  4) XKB="de,us" ;;  5) XKB="de,gb" ;;
  6) read -rp "xkb-Layouts: " XKB; XKB="${XKB:-de}" ;;
  *) XKB="de" ;;
esac

# Kernel-Wahl: Mainline (latest) ist der Flotten-VORSCHLAGSWERT in modules/desktop.nix
# (mkDefault) — Hintergrund: der LTS-i915 scheiterte auf Meteor Lake an MST-Daisy-
# Chains mit DSC; Fehlerbild + Plattform-Grenzen: docs/troubleshooting.md, Abschnitt J.
# 'n' schreibt einen LTS-Override in die Host-Config (normale Zuweisung genuegt).
echo
read -rp "Mainline-Kernel (latest) verwenden? [J/n]: " KM
case "$KM" in
  [nN]*) KERNEL_LINE='  boot.kernelPackages = pkgs.linuxPackages;   # LTS statt Flotten-Vorschlag Mainline (s. modules/desktop.nix)'
         KERNEL_DESC='LTS (Host-Override)' ;;
  *)     KERNEL_LINE='  # Kernel: Flotten-Vorschlag Mainline/latest greift (mkDefault in modules/desktop.nix) — kein Override.'
         KERNEL_DESC='Mainline/latest (Flotten-Vorschlag)' ;;
esac

# Optional: generische Update-Erinnerung (Desktop-Icon + stuendlicher Notify-Timer + update-all.sh
# + fwupd fuer Firmware/BIOS). Erzeugt modules/host-updates.nix + update-all.sh und haengt das
# Modul in die Host-Config. Default J (Enter = installieren): Die Update-Mechanik gehoert zur
# Basis — der alte Default N wurde beim Durchklicken still uebersprungen (docs/troubleshooting.md, D).
echo
read -rp "Update-Erinnerung installieren? (Desktop-Icon + stuendlicher Update-Check + fwupd) [J/n]: " HU
case "$HU" in [nN]*) HOSTUPDATES=0 ;; *) HOSTUPDATES=1 ;; esac

# Optional: Host-Haertung nach BSI SYS.2.3 (AppArmor, USBGuard-Whitelist aus dem Ist-Zustand,
# sysctl-Kernel-Haertung, udisks2-noexec fuer Wechselmedien, GC-/Log-Deckel). Erzeugt
# modules/hardening.nix (+ hosts/<host>/usbguard-rules.conf, wenn erzeugbar) und haengt das
# Modul in die Host-Config. Default J: gehoert wie die Update-Mechanik zur Basis.
echo
read -rp "Host-Haertung nach BSI SYS.2.3 einrichten? (AppArmor, USBGuard, sysctl) [J/n]: " HD
case "$HD" in [nN]*) HARDENING=0 ;; *) HARDENING=1 ;; esac

# Optional: dGPU an vfio-pci binden fuer D3cold-Stromsparen — nur wenn oben eine D3cold-faehige
# dGPU erkannt wurde (sonst erscheint die Frage gar nicht).
VFIO_D3COLD=0
if [ -n "$DGPU_GPU_ID" ]; then
  echo
  echo "Dedizierte GPU erkannt: $DGPU_ADDR  ($DGPU_GPU_ID${DGPU_AUDIO_ID:+ + Audio $DGPU_AUDIO_ID})  — D3cold-faehig (_PR3 am Parent-Port)."
  echo
  echo "An vfio-pci binden heisst: der Slot wird im Leerlauf komplett stromlos (echtes D3cold)"
  echo "— auf Hybrid-Laptops spuerbar mehr Akku, da der Desktop ohnehin auf der iGPU laeuft."
  echo "WOZU man das will:  (a) Vorbereitung fuer GPU-Passthrough an eine VM"
  echo "                        (z. B. die VM-Suite-Extension, s. docs/README-payload.md),"
  echo "                    (b) reines Stromsparen, wenn die dGPU nie gebraucht wird."
  echo "PREIS: die GPU ist fuer den HOST unbrauchbar (kein CUDA, kein Host-Gaming)."
  echo "DRITTER WEG (ohne vfio, spaeter nachruestbar): proprietaerer Treiber + RTD3 ="
  echo "gleiches D3cold MIT Host-Nutzbarkeit — Anleitung: docs/troubleshooting.md, E."
  read -rp "dGPU an vfio-pci binden? [j/N]: " VF
  case "$VF" in [jJyY]*) VFIO_D3COLD=1 ;; *) VFIO_D3COLD=0 ;; esac
fi

# ===================== 2. Zielplatte erkennen =====================
echo
echo "Verfuegbare Datenträger (USB/zram ausgeblendet):"
lsblk -dpno NAME,SIZE,MODEL,TRAN | grep -viE 'usb|loop|zram' || true
echo "  (Falls deine Platte fehlt: in anderem Terminal 'lsblk' pruefen.)"
# Interne Platten als Auswahl-Kandidaten sammeln:
# TYPE=disk (also kein loop/crypt), nicht USB, nicht wechselbar, kein zram.
# zram (RAM-Swap) hat TYPE=disk und wuerde sonst als zweite "Platte" auftauchen.
DISK_CANDS=()
while read -r _name; do
  [ -n "$_name" ] || continue
  case "$_name" in */zram*) continue ;; esac   # zram (RAM-Swap) ist nie ein Installationsziel
  if [ "$(lsblk -dno TYPE "$_name" 2>/dev/null)" != "disk" ]; then continue; fi
  if [ "$(lsblk -dno TRAN "$_name" 2>/dev/null)" = "usb" ]; then continue; fi
  if [ "$(lsblk -dno RM   "$_name" 2>/dev/null)" = "1" ]; then continue; fi
  DISK_CANDS+=("$_name")
done < <(lsblk -dpno NAME)

NCANDS="${#DISK_CANDS[@]}"

# stabile by-id zu einem /dev-Pfad ermitteln (eui/wwn bevorzugt, sonst model-serial)
resolve_byid() {
  local dev b="" link
  dev="$(readlink -f "$1")"
  for link in /dev/disk/by-id/*; do
    [ -e "$link" ] || continue
    case "$link" in *-part*) continue ;; esac
    if [ "$(readlink -f "$link")" = "$dev" ]; then
      case "$link" in
        */nvme-eui.*|*/wwn-*) echo "$link"; return 0 ;;
        *) [ -z "$b" ] && b="$link" ;;
      esac
    fi
  done
  [ -n "$b" ] && echo "$b" || echo "$1"
}

_is_num() { printf '%s' "$1" | grep -qE '^[0-9]+$'; }
_show_list() {
  local i=1 d
  echo "Erkannte interne Platten:"
  for d in "${DISK_CANDS[@]}"; do printf "  %d) %s\n" "$i" "$(lsblk -dpno NAME,SIZE,MODEL "$d" 2>/dev/null)"; i=$((i+1)); done
}
_pick_one() {   # gibt den gewaehlten /dev-Pfad auf stdout aus (Nummer aus Liste oder Pfad)
  local prompt="$1" sel n
  while true; do
    printf '%s' "$prompt" >&2
    read -r sel; sel="${sel:-1}"
    if _is_num "$sel"; then
      n=$((10#$sel))
      if [ "$n" -ge 1 ] && [ "$n" -le "$NCANDS" ]; then printf '%s' "${DISK_CANDS[$((n - 1))]}"; return 0; fi
      echo "  Ungültige Nummer (1..$NCANDS) — bitte erneut." >&2; continue
    fi
    if [ -b "$sel" ]; then printf '%s' "$sel"; return 0; fi
    echo "  '$sel' ist weder Nummer (1..$NCANDS) noch Blockgerät — bitte erneut." >&2
  done
}

# ---- Modus bestimmen (nur bei mehreren Platten gibt es eine Wahl) ----
if [ "$NCANDS" -ge 2 ]; then
  echo
  _show_list
  echo
  echo "Modus bei mehreren Platten:"
  echo "  1) Eine Platte            (Standard, am besten getestet)"
  echo "  2) Pool      - mdadm-RAID0 + LUKS + btrfs   (mehr Platz, KEINE Redundanz)"
  echo "  3) Spiegel   - mdadm-RAID1 + LUKS + btrfs   (ausfallsicher, Platz = kleinste Platte)"
  echo "  4) Getrennte Rollen - System auf 1 Platte, Rest als verschluesselte Datenplatten"
  echo "  HINWEIS: 2-4 sind EXPERIMENTELL (hier nicht auf Hardware getestet) -> --dry-run + disk.nix pruefen!"
  read -rp "Modus [1]: " MSEL; MSEL="${MSEL:-1}"
  case "$MSEL" in 2) MODE="pool" ;; 3) MODE="raid1" ;; 4) MODE="separate" ;; *) MODE="single" ;; esac
else
  MODE="single"
fi

# ---- Geraete je Modus auswaehlen + by-id aufloesen ----
DISK=""; BYID=""; BYIDS=(); DATA_BYIDS=(); MODE_DESC=""; DISKS_DESC=""; LVL=0

case "$MODE" in
  single)
    if [ "$NCANDS" -ge 2 ]; then
      DISK="$(_pick_one "Welche Platte? [1] (Nummer oder Gerätepfad) — WIRD VOLLSTAENDIG GELOESCHT: ")"
    elif [ "$NCANDS" -eq 1 ]; then
      DEFAULT_DISK="${DISK_CANDS[0]}"
      while true; do
        read -rp "Ziel-Datenträger [${DEFAULT_DISK}] — WIRD VOLLSTAENDIG GELOESCHT (Enter = Default, Strg-C = Abbruch): " DISK
        DISK="${DISK:-$DEFAULT_DISK}"; [ -b "$DISK" ] && break
        echo "  '$DISK' ist kein Blockgerät — bitte erneut eingeben." >&2
      done
    else
      while true; do
        read -rp "Ziel-Datenträger (z.B. /dev/nvme0n1) — WIRD VOLLSTAENDIG GELOESCHT (Strg-C = Abbruch): " DISK
        [ -n "$DISK" ] || { echo "  Bitte einen Gerätepfad angeben." >&2; continue; }
        [ -b "$DISK" ] && break; echo "  '$DISK' ist kein Blockgerät — bitte erneut eingeben." >&2
      done
    fi
    BYID="$(resolve_byid "$DISK")"
    MODE_DESC="Eine Platte (LUKS + btrfs)"
    DISKS_DESC="  - $BYID   ($DISK)"
    ;;

  pool|raid1)
    if [ "$MODE" = "pool" ]; then LVL=0; MODE_DESC="Pool / mdadm-RAID0 + LUKS + btrfs (KEINE Redundanz)";
    else LVL=1; MODE_DESC="Spiegel / mdadm-RAID1 + LUKS + btrfs (ausfallsicher)"; fi
    while true; do
      read -rp "Welche Platten in den Verbund? (verschiedene Nummern, z.B. 1,2  oder 'alle') [alle]: " MSEL2
      MSEL2="${MSEL2:-alle}"; _seldevs=()
      if [ "$MSEL2" = "alle" ] || [ "$MSEL2" = "all" ]; then
        _seldevs=("${DISK_CANDS[@]}")
      else
        _ok=1; IFS=', ' read -ra _parts <<< "$MSEL2" || true
        for _p in "${_parts[@]}"; do
          [ -n "$_p" ] || continue
          if _is_num "$_p"; then _n2=$((10#$_p))
            if [ "$_n2" -ge 1 ] && [ "$_n2" -le "$NCANDS" ]; then _seldevs+=("${DISK_CANDS[$((_n2 - 1))]}"); else _ok=0; fi
          else _ok=0; fi
        done
        [ "$_ok" = "1" ] || { echo "  Ungültige Auswahl (Nummern 1..$NCANDS)." >&2; continue; }
      fi
      [ "${#_seldevs[@]}" -ge 2 ] && break
      echo "  Bitte mindestens 2 Platten waehlen." >&2
    done
    _first=1
    for _d in "${_seldevs[@]}"; do
      _b="$(resolve_byid "$_d")"; BYIDS+=("$_b")
      if [ "$_first" = "1" ]; then DISKS_DESC="  - $_b   (ESP + RAID-Mitglied)"; _first=0
      else DISKS_DESC="$DISKS_DESC
  - $_b   (RAID-Mitglied)"; fi
    done
    ;;

  separate)
    MODE_DESC="Getrennte Rollen (System + Datenplatten, je LUKS+btrfs)"
    _sysdev="$(_pick_one "System-Platte? [1] (Nummer oder Gerätepfad) — WIRD VOLLSTAENDIG GELOESCHT: ")"
    BYID="$(resolve_byid "$_sysdev")"
    DISKS_DESC="  - $BYID   (System: ESP + root)"
    _n3=2
    for _d in "${DISK_CANDS[@]}"; do
      [ "$(readlink -f "$_d")" = "$(readlink -f "$_sysdev")" ] && continue
      _b="$(resolve_byid "$_d")"; DATA_BYIDS+=("$_b")
      DISKS_DESC="$DISKS_DESC
  - $_b   (Daten -> /data$_n3)"
      _n3=$((_n3 + 1))
    done
    ;;
esac

# Hardware-Report fuer den spaeteren vfio-Schritt (nur Referenz)
REPORT_GPU="$(lspci -nn | grep -Ei '3d|vga|display' || true)"
REPORT_NET="$(lspci -nn | grep -Ei 'network|wireless' || true)"

# ===================== 3. Zusammenfassung + Bestaetigung =====================
case "$XKB" in *,*) MULTI="ja (Alt+Shift)" ;; *) MULTI="nein" ;; esac
if [ "$VFIO_D3COLD" = "1" ]; then
  VFIO_DESC="ja -> $DGPU_GPU_ID${DGPU_AUDIO_ID:+ + $DGPU_AUDIO_ID}  (GPU wird dem HOST entzogen)"
else
  VFIO_DESC="nein"
fi
cat <<SUMMARY

==================== Zusammenfassung ====================
  Hostname   : $HOST
  Benutzer   : $USER_
  Zeitzone   : $TZ
  Locale     : $LOC
  Tastatur   : $XKB    (mehrere Layouts: $MULTI)
  Kernel     : $KERNEL_DESC
  Haertung   : $( [ "$HARDENING" = "1" ] && echo "ja (SYS.2.3: AppArmor, USBGuard, sysctl)" || echo "nein" )
  Layout     : $MODE_DESC
  dGPU->vfio : $VFIO_DESC
  Platten    : (werden VOLLSTAENDIG GELOESCHT)
$DISKS_DESC
  Aktion     : $( [ "$DRY_RUN" = "1" ] && echo "DRY_RUN (nur Dateien)" || echo "ECHT (installiert)" )
========================================================
SUMMARY
read -rp "Alles korrekt? Tippe GROSS 'JA': " OK
[ "$OK" = "JA" ] || { echo "Abgebrochen."; exit 1; }

# ===================== 4. Repo + Dateien erzeugen =====================
REPO="$HOME/nixos-config"
mkdir -p "$REPO/hosts/$HOST"
cd "$REPO"
git init -q 2>/dev/null || true
printf 'result\nresult-*\n*.swp\n' > .gitignore

# ── Basis-Payload einspielen: alle zentral gepflegten Dateien 1:1 aus files/ ──
# (Module, update-all.sh, USBGuard-Werkzeuge, check-vfio.sh, Doku, Auto-Discovery-
# flake.nix.) Immer ALLE — Module sind Infrastruktur; ob eines wirkt, entscheidet
# allein der IMPORTS-Block der Host-Config (die J/n-Prompts oben). Exec-Bits
# reisen mit. Architektur/Update-Fluss: docs/README-payload.md (liegt danach im Repo).
cp -r "$SCRIPT_DIR/files/." .

# payload-sources.conf: verbindet das neue Repo mit dem zentralen Basis-Payload —
# update-all.sh (Abschnitt 0b) zieht Updates kuenftig von dort, nach Diff + Gate.
PL_URL="$(git -C "$SCRIPT_DIR" remote get-url origin 2>/dev/null || true)"
{
  printf '# payload-sources.conf — Quellen fuer update-all.sh, Abschnitt 0b.\n'
  printf '# Format: name=url-oder-pfad[#ref] · Pinning/Spiegel: docs/README-payload.md\n'
  if [ -n "$PL_URL" ]; then
    printf 'basis=%s\n' "$PL_URL"
  else
    printf '# basis=<url-des-installer-repos>   # nicht ermittelbar (kein git-Klon?) — bitte eintragen\n'
  fi
  printf '# extensions=<url-nach-kauf>#<tag>\n'
} > payload-sources.conf

# flake.nix kommt aus dem Basis-Payload (files/): Auto-Discovery — neue Hosts
# (hosts/<name>/ mit hardware-configuration.nix + disk.nix) und VM-Gaeste werden
# ohne Flake-Aenderung erkannt; disko wird fuer physische Hosts automatisch verdrahtet.

# Wiederkehrender btrfs-Root (5 Subvolumes). Nix ist whitespace-unempfindlich,
# daher als Variable wiederverwendbar.
ROOT_SUBVOLS='subvolumes = {
                "/root"    = { mountpoint = "/";        mountOptions = [ "compress=zstd" "noatime" ]; };
                "/home"    = { mountpoint = "/home";    mountOptions = [ "compress=zstd" "noatime" ]; };
                "/nix"     = { mountpoint = "/nix";     mountOptions = [ "compress=zstd" "noatime" ]; };
                "/persist" = { mountpoint = "/persist"; mountOptions = [ "compress=zstd" "noatime" ]; };
                "/log"     = { mountpoint = "/var/log"; mountOptions = [ "compress=zstd" "noatime" ]; };
              };'

DISKNIX="hosts/$HOST/disk.nix"
case "$MODE" in
  single)
    cat > "$DISKNIX" <<EOF
{
  disko.devices.disk.main = {
    type = "disk";
    device = "$BYID";
    content = {
      type = "gpt";
      partitions = {
        ESP = { priority = 1; size = "2G"; type = "EF00";
          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; mountOptions = [ "umask=0077" ]; }; };
        luks = { size = "100%";
          content = { type = "luks"; name = "cryptroot"; settings.allowDiscards = true;
            content = { type = "btrfs"; extraArgs = [ "-f" ];
              $ROOT_SUBVOLS
            };
          };
        };
      };
    };
  };
}
EOF
    ;;

  pool|raid1)
    # Jede Platte: GPT mit mdraid-Mitglied (erste Platte zusaetzlich mit ESP).
    # Darueber EIN mdadm-Verbund -> EIN LUKS -> btrfs (eine Passphrase, identische Root-Schicht).
    {
      echo "{"
      echo "  disko.devices = {"
      echo "    disk = {"
      _i=1
      for _b in "${BYIDS[@]}"; do
        if [ "$_i" -eq 1 ]; then
          cat <<EOF
      disk$_i = {
        type = "disk";
        device = "$_b";
        content = {
          type = "gpt";
          partitions = {
            ESP = { priority = 1; size = "2G"; type = "EF00";
              content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; mountOptions = [ "umask=0077" ]; }; };
            raid = { size = "100%"; content = { type = "mdraid"; name = "osraid"; }; };
          };
        };
      };
EOF
        else
          cat <<EOF
      disk$_i = {
        type = "disk";
        device = "$_b";
        content = { type = "gpt"; partitions = {
          raid = { size = "100%"; content = { type = "mdraid"; name = "osraid"; }; };
        }; };
      };
EOF
        fi
        _i=$((_i + 1))
      done
      cat <<EOF
    };
    mdadm.osraid = {
      type = "mdadm";
      level = $LVL;
      content = {
        type = "luks"; name = "cryptroot"; settings.allowDiscards = true;
        content = { type = "btrfs"; extraArgs = [ "-f" ];
          $ROOT_SUBVOLS
        };
      };
    };
  };
}
EOF
    } > "$DISKNIX"
    ;;

  separate)
    # System-Platte (ESP + LUKS + btrfs root) + je Datenplatte eigenes LUKS + btrfs.
    # Gleiche Passphrase verwenden -> systemd-initrd entsperrt i.d.R. mit einer Eingabe.
    {
      echo "{"
      echo "  disko.devices.disk = {"
      cat <<EOF
    main = {
      type = "disk";
      device = "$BYID";
      content = {
        type = "gpt";
        partitions = {
          ESP = { priority = 1; size = "2G"; type = "EF00";
            content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; mountOptions = [ "umask=0077" ]; }; };
          luks = { size = "100%";
            content = { type = "luks"; name = "cryptroot"; settings.allowDiscards = true;
              content = { type = "btrfs"; extraArgs = [ "-f" ];
                $ROOT_SUBVOLS
              };
            };
          };
        };
      };
    };
EOF
      _n=2
      for _b in "${DATA_BYIDS[@]}"; do
        cat <<EOF
    data$_n = {
      type = "disk";
      device = "$_b";
      content = { type = "gpt"; partitions = {
        luks = { size = "100%";
          content = { type = "luks"; name = "cryptdata$_n"; settings.allowDiscards = true;
            content = { type = "btrfs"; extraArgs = [ "-f" ];
              subvolumes = { "/data" = { mountpoint = "/data$_n"; mountOptions = [ "compress=zstd" "noatime" ]; }; };
            };
          };
        };
      }; };
    };
EOF
        _n=$((_n + 1))
      done
      echo "  };"
      echo "}"
    } > "$DISKNIX"
    ;;
esac

XKBOPT=""
case "$XKB" in *,*) XKBOPT='  services.xserver.xkb.options = "grp:alt_shift_toggle";' ;; esac

# modules/desktop.nix kommt aus dem Basis-Payload (files/). Die Prompt-Antworten
# (Zeitzone/Locale/Tastatur/Kernel) landen unten als NORMALE Zuweisungen in der
# Host-Config — sie uebersteuern die mkDefault-Vorschlagswerte des Moduls
# (Drei-Ebenen-Regel: docs/nixos-cheatsheet.md §13).

# ── Schlanke Host-Config: importiert das/die Modul(e) + nur das Host-Spezifische ──
# host-updates.nix wird nur eingehaengt, wenn oben danach gefragt wurde (HOSTUPDATES=1).
IMPORTS="    ../../modules/desktop.nix"
if [ "$HOSTUPDATES" = "1" ]; then
  IMPORTS="$IMPORTS
    ../../modules/host-updates.nix"
fi
if [ "$VFIO_D3COLD" = "1" ]; then
  IMPORTS="$IMPORTS
    ../../modules/vfio.nix"
fi
if [ "$HARDENING" = "1" ]; then
  IMPORTS="$IMPORTS
    ../../modules/hardening.nix"
fi

# ── Haertung: USBGuard-Whitelist aus dem Ist-Zustand des Live-Systems erzeugen ──
# Das Live-ISO sieht dieselbe Hardware wie das installierte System -> generate-policy
# liefert gueltige Regeln (interne Geraete wie Bluetooth/Webcam inklusive). Die
# usbguard-CLI kommt fluechtig aus nixpkgs (kein Eingriff ins Live-System). Schlaegt
# das fehl (offline, keine allow-Regeln): Modul bleibt trotzdem eingehaengt, USBGuard
# bleibt AUS (konservativer Modul-Default ohne rulesFile) -> nach dem ersten Boot
# nachziehen mit 'bash usbguard-sync.sh --init' (liegt via files/ bereits im Repo).
# Bei DRY_RUN wird die Erzeugung uebersprungen (dry-run ruft bewusst kein sudo).
HARDENING_CONFIG=""
if [ "$HARDENING" = "1" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "  -> DRY_RUN: USBGuard-Whitelist wird nicht erzeugt (braeuchte sudo) — USBGuard bliebe aus."
  else
    _ug=""
    if _ugpath="$(nix --extra-experimental-features 'nix-command flakes' \
                    build --no-link --print-out-paths nixpkgs#usbguard 2>/dev/null)"; then
      _ug="${_ugpath}/bin/usbguard"
    fi
    if [ -n "$_ug" ] && [ -x "$_ug" ] \
       && {
            printf '# hosts/%s/usbguard-rules.conf — gepinnte USBGuard-Whitelist.\n' "$HOST"
            printf '# Quelle: usbguard generate-policy am %s (install.sh, Live-System).\n' "$(date +%Y-%m-%d)"
            printf '# Alles, was hier NICHT steht, wird geblockt. Pflege: usbguard-sync.sh --add\n'
            printf '# (nie lokal per append-rule — Regeln kommen ausschliesslich aus dem Repo).\n\n'
            sudo "$_ug" generate-policy
          } > "hosts/$HOST/usbguard-rules.conf" 2>/dev/null \
       && grep -q '^allow ' "hosts/$HOST/usbguard-rules.conf"; then
      HARDENING_CONFIG="
  # Gepinnte USBGuard-Whitelist dieses Geraets (SYS.2.3.A14) — Pflege NUR ueber diese
  # Datei (Workflow: usbguard-sync.sh; Doku: docs/README-hardening.md).
  hardening.usbguard.rulesFile = ./usbguard-rules.conf;"
      echo "  -> hosts/$HOST/usbguard-rules.conf erzeugt ($(grep -c '^allow ' "hosts/$HOST/usbguard-rules.conf") Regeln) — USBGuard aktiv ab dem ersten Boot."
    else
      rm -f "hosts/$HOST/usbguard-rules.conf"
      echo "WARN: USBGuard-Whitelist nicht erzeugbar (offline / keine allow-Regeln) —" >&2
      echo "      Haertung wird OHNE USBGuard installiert (Modul-Default: aus)." >&2
      echo "      Nachziehen nach dem ersten Boot: bash usbguard-sync.sh --init" >&2
    fi
  fi
fi

# vfio-Eintraege fuer die Host-Config (nur bei VFIO_D3COLD=1; sonst leer): host.passthroughIds +
# passthroughUser (-> User in die libvirtd-Gruppe) + Vendor-Blacklist als Fallback.
VFIO_CONFIG=""
if [ "$VFIO_D3COLD" = "1" ]; then
  _ids="\"$DGPU_GPU_ID\""
  [ -n "$DGPU_AUDIO_ID" ] && _ids="$_ids \"$DGPU_AUDIO_ID\""
  case "$DGPU_VENDOR" in
    10de) _bl='[ "nouveau" "nvidiafb" ]' ;;   # NVIDIA
    1002) _bl='[ "amdgpu" "radeon" ]' ;;      # AMD
    *)    _bl="" ;;
  esac
  VFIO_CONFIG="
  # dGPU an vfio-pci binden -> im Leerlauf D3cold (Slot stromlos), erkannt ueber _PR3 am Parent-Port.
  # Macht die GPU fuer den Host unbrauchbar (nur VM-Passthrough). Geteiltes Modul: modules/vfio.nix.
  host.passthroughIds  = [ $_ids ];
  host.passthroughUser = \"$USER_\";"
  [ -n "$_bl" ] && VFIO_CONFIG="$VFIO_CONFIG
  boot.blacklistedKernelModules = $_bl;   # Fallback: bleibt treiberlos, falls vfio-pci nicht greift"
fi
cat > "hosts/$HOST/configuration.nix" <<EOF
{ pkgs, ... }:
{
  imports = [
$IMPORTS
  ];

  networking.hostName = "$HOST";

  # Personalisierte Vorgaben aus den Installer-Prompts — uebersteuern die
  # mkDefault-Vorschlagswerte in modules/desktop.nix (normale Zuweisung genuegt;
  # Drei-Ebenen-Regel: docs/nixos-cheatsheet.md §13).
  time.timeZone = "$TZ";
  i18n.defaultLocale = "$LOC";
  services.xserver.xkb.layout = "$XKB";
$XKBOPT
$KERNEL_LINE
$VFIO_CONFIG$HARDENING_CONFIG
  users.users.$USER_ = {
    isNormalUser = true;
    description = "$USER_";
    extraGroups = [ "wheel" "networkmanager" ];
    hashedPasswordFile = "/persist/secrets/$USER_.hash";
  };
  users.users.root.hashedPasswordFile = "/persist/secrets/root.hash";

  system.stateVersion = "26.05";
}
EOF

# host-updates.nix + update-all.sh kommen aus dem Basis-Payload (files/) — die
# Update-Erinnerung wirkt nur, wenn 'J' oben das Modul in IMPORTS eingehaengt hat.

# modules/vfio.nix kommt aus dem Basis-Payload (files/) — es wirkt nur, wenn die
# Host-Config host.passthroughIds setzt (VFIO_CONFIG oben; sonst reiner No-op).

# modules/hardening.nix kommt aus dem Basis-Payload (files/) — es wirkt nur via
# IMPORTS ('J' oben); USBGuard zusaetzlich erst mit rulesFile (HARDENING_CONFIG).


cat > "hosts/$HOST/DETECTED-HARDWARE.txt" <<EOF
# Automatisch erkannt am $(date -Iseconds) — Referenz fuer den spaeteren vfio-Schritt.
# (Nicht Teil der aktiven Config.)

## GPU(s)
$REPORT_GPU

## Netzwerk / WLAN
$REPORT_NET
EOF

echo "==> Config erzeugt unter $REPO"

if [ "$DRY_RUN" = "1" ]; then
  echo "==> DRY_RUN: Installation uebersprungen. Pruefe die Dateien in $REPO."
  exit 0
fi

# ===================== 5. disko + hardware-config + Passwoerter + Install =====================

# Sicherheit vor dem Loeschen: alle Zielgeraete einsammeln (real aufgeloest + dedupliziert).
TARGETS=()
[ -n "${DISK:-}" ] && TARGETS+=("$(readlink -f "$DISK")")
[ -n "${BYID:-}" ] && TARGETS+=("$(readlink -f "$BYID")")
for _x in "${BYIDS[@]}";      do [ -n "$_x" ] && TARGETS+=("$(readlink -f "$_x")"); done
for _x in "${DATA_BYIDS[@]}"; do [ -n "$_x" ] && TARGETS+=("$(readlink -f "$_x")"); done
mapfile -t TARGETS < <(printf '%s\n' "${TARGETS[@]}" | awk 'NF && !seen[$0]++')

# (1) Keine Ziel-Platte darf aktuell gemountet sein (sonst falsche/benutzte Platte).
for _d in "${TARGETS[@]}"; do
  _m="$(lsblk -nro MOUNTPOINT "$_d" 2>/dev/null | grep -v '^$' || true)"
  [ -n "$_m" ] || continue
  echo "FEHLER: Auf der Ziel-Platte $_d sind aktuell Dateisysteme gemountet:" >&2
  printf '   %s\n' $_m >&2
  if [ "${ALLOW_NONLIVE:-0}" = "1" ]; then
    echo "WARN: ALLOW_NONLIVE=1 — fahre trotz Mounts fort (disko versucht auszuhaengen)." >&2
  else
    echo "        Bitte zuerst 'umount' oder vom ISO booten. (Override: ALLOW_NONLIVE=1)" >&2
    exit 1
  fi
done

# (2) Wurde der Live-Guard per Override umgangen: zusaetzliche GETIPPTE Bestaetigung der Hauptplatte.
if [ "${NONLIVE:-0}" = "1" ]; then
  _primary="$(readlink -f "${DISK:-${BYID:-}}" 2>/dev/null || true)"
  [ -n "$_primary" ] || _primary="${TARGETS[0]:-}"
  echo
  echo "!!! ACHTUNG: Du umgehst die Live-System-Pruefung (ALLOW_NONLIVE=1)."
  echo "!!! Folgende Platte(n) werden GLEICH UNWIDERRUFLICH GELOESCHT:"
  printf '      %s\n' "${TARGETS[@]}"
  read -rp "Zum Bestaetigen den EXAKTEN Pfad der Hauptplatte tippen ($_primary): " _confirm
  [ "$_confirm" = "$_primary" ] || { echo "Eingabe stimmt nicht — Abbruch." >&2; exit 1; }
fi

echo "==> Platte wird partitioniert/verschluesselt (disko fragt nochmal + LUKS-Passphrase)."
sudo nix --experimental-features "nix-command flakes" \
  run github:nix-community/disko/latest -- \
  --mode destroy,format,mount "./hosts/$HOST/disk.nix"

sudo nixos-generate-config --no-filesystems --root /mnt
sudo cp /mnt/etc/nixos/hardware-configuration.nix "hosts/$HOST/hardware-configuration.nix"

sudo mkdir -p /mnt/persist/secrets

# Passwort verdeckt + doppelt abfragen, abgleichen, dann als yescrypt-Hash speichern.
ask_password() {   # $1 = Anzeige-Name; gibt den Hash auf stdout aus
  local p1 p2 h
  while true; do
    printf "==> Passwort fuer %s: " "$1" >&2
    read -rs p1 </dev/tty; printf '\n' >&2
    printf "    Passwort wiederholen: " >&2
    read -rs p2 </dev/tty; printf '\n' >&2
    if [ -z "$p1" ]; then printf "    Leer - bitte erneut.\n" >&2; continue; fi
    if [ "$p1" != "$p2" ]; then printf "    Passwoerter stimmen nicht ueberein - bitte erneut.\n" >&2; continue; fi
    h="$(printf '%s' "$p1" | mkpasswd -m yescrypt -s)" || { printf "    mkpasswd-Fehler - bitte erneut.\n" >&2; continue; }
    [ -n "$h" ] || { printf "    leerer Hash - bitte erneut.\n" >&2; continue; }
    printf '%s' "$h"; return 0
  done
}
ask_password "Benutzer '$USER_'" | sudo tee "/mnt/persist/secrets/$USER_.hash" >/dev/null
ask_password "'root'"            | sudo tee /mnt/persist/secrets/root.hash >/dev/null
sudo chmod 600 /mnt/persist/secrets/*.hash
# Sicherheitsnetz: leere Hash-Dateien wuerden Login unmoeglich machen.
for _hf in "/mnt/persist/secrets/$USER_.hash" /mnt/persist/secrets/root.hash; do
  sudo test -s "$_hf" || { echo "FEHLER: $_hf ist leer - Abbruch (sonst kein Login moeglich)." >&2; exit 1; }
done

# ── RAM-Schonung fuer den Build (wichtig bei wenig Arbeitsspeicher, z.B. 8 GB) ──────
# Das Live-ISO legt /tmp ins RAM (tmpfs) -> grosse Nix-Builds sprengen sonst den Speicher.
MEM_GB=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)
LOWMEM=0; [ "${MEM_GB:-99}" -lt 12 ] && LOWMEM=1

# Build-Temp immer auf die frische Platte umlenken (raus aus dem RAM-tmpfs) - schadet nie.
sudo mkdir -p /mnt/tmp
export TMPDIR=/mnt/tmp

# Temporaere Swap-Datei nur bei wenig RAM und wenn keiner aktiv ist (nach Installation entfernt).
SWAPFILE=/mnt/installer-swap
cleanup_swap() { sudo swapoff "$SWAPFILE" 2>/dev/null || true; sudo rm -f "$SWAPFILE" 2>/dev/null || true; }
if [ "$LOWMEM" = "1" ] && [ "$(swapon --show --noheadings 2>/dev/null | wc -l)" -eq 0 ]; then
  echo "==> Wenig RAM (${MEM_GB} GB): temporaere 8G-Swap-Datei anlegen ($SWAPFILE)."
  if sudo fallocate -l 8G "$SWAPFILE" 2>/dev/null || sudo dd if=/dev/zero of="$SWAPFILE" bs=1M count=8192 status=none; then
    sudo chmod 600 "$SWAPFILE"
    sudo mkswap "$SWAPFILE" >/dev/null && sudo swapon "$SWAPFILE" && trap cleanup_swap EXIT
  else
    echo "WARN: Swap-Datei konnte nicht angelegt werden - fahre ohne fort." >&2
  fi
fi

# Nix-Build-Optionen: bei wenig RAM auf 1 Job/1 Core drosseln (langsamer, aber speicherschonend).
NIXOPTS="extra-experimental-features = nix-command flakes"
if [ "$LOWMEM" = "1" ]; then
  echo "==> Wenig RAM: Build wird auf max-jobs=1 / cores=1 gedrosselt (langsamer, dafuer stabil)."
  NIXOPTS="$NIXOPTS
max-jobs = 1
cores = 1"
fi

git add -A
git -c user.email=installer@localhost -c user.name=installer commit -q -m "Initiale Config ($HOST)" || true
sudo env TMPDIR=/mnt/tmp NIX_CONFIG="$NIXOPTS" \
  nixos-install --flake ".#$HOST" --no-root-passwd

# Generierte Config aufs installierte System uebernehmen (sonst nur im Live-System vorhanden)
if [ -d "/mnt/home/$USER_" ]; then
  sudo cp -r "$REPO" "/mnt/home/$USER_/nixos-config" \
    && sudo chown -R --reference="/mnt/home/$USER_" "/mnt/home/$USER_/nixos-config" \
    && echo "==> Config nach /home/$USER_/nixos-config kopiert (bleibt nach dem Reboot erhalten)." \
    || echo "WARN: Kopie fehlgeschlagen - sichere ~/nixos-config manuell vor dem Reboot." >&2
else
  echo "WARN: /mnt/home/$USER_ fehlt - sichere ~/nixos-config manuell vor dem Reboot." >&2
fi

echo
echo "==> Fertig. Config liegt auf dem System unter /home/$USER_/nixos-config."
if [ "$HOSTUPDATES" = "1" ]; then
  echo "==> Update-Erinnerung: INSTALLIERT (Icon 'NixOS aktualisieren' + stuendlicher Check + fwupd)."
else
  echo "==> Update-Erinnerung: UEBERSPRUNGEN (Prompt mit 'n' beantwortet)."
  echo "    Nachruesten ohne Neuinstallation: docs/troubleshooting.md -> Abschnitt D."
fi
if [ "$HARDENING" = "1" ]; then
  if [ -f "hosts/$HOST/usbguard-rules.conf" ]; then
    echo "==> Haertung (SYS.2.3): INSTALLIERT — USBGuard aktiv ab dem ersten Boot."
    echo "    Verifikation nach dem Boot: usbguard list-devices --blocked  -> muss leer sein."
  else
    echo "==> Haertung (SYS.2.3): INSTALLIERT — USBGuard noch AUS (keine Whitelist erzeugt)."
    echo "    Nachziehen: bash usbguard-sync.sh --init  (liegt im Repo; Doku: docs/README-hardening.md)."
  fi
else
  echo "==> Haertung (SYS.2.3): UEBERSPRUNGEN (Prompt mit 'n' beantwortet)."
  echo "    Nachruesten: Import-Zeile in der Host-Config — das Modul liegt bereits im Repo (docs/README-hardening.md)."
fi
echo "==> Payload: Basis aus files/ eingespielt, payload-sources.conf angelegt — zentrale"
echo "    Updates kuenftig via 'bash update-all.sh' (Abschnitt 0b; docs/README-payload.md)."
echo "==> Extensions (optional, kostenpflichtig — z. B. VM-Suite): docs/README-payload.md, §6."
echo "==> Stick ziehen und 'sudo reboot'."
