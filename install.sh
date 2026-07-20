#!/usr/bin/env bash
#
# Generischer NixOS-First-Boot-Installer.
# Fragt Hostname/Benutzer/Tastatur ab, erkennt die Zielplatte, erzeugt das
# Config-Repo unter ~/nixos-config und installiert. Keine persoenlichen Daten im Skript.
#
# Pruef-Lauf (nur Dateien erzeugen, nichts loeschen):
#   bash install.sh --dry-run
# Echter Lauf:
#   bash install.sh
# (Das Skript holt fehlende Tools - git/mkpasswd/pciutils - selbst via nix-shell.)
#
set -euo pipefail

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
# Alle Eingaben werden validiert und bei Fehleingabe erneut abgefragt. Hintergrund (Praxisfall):
# Bei der frueher freien Locale-Frage wurde einmal "1" eingegeben (im Nummern-Rhythmus der
# Menues) -> landete ungeprueft als i18n.defaultLocale = "1" in modules/desktop.nix -> der
# glibc-locales-Build bricht erst SPAET im nixos-install ab ("unsupported locales detected:
# 1/UTF-8"). Deshalb: frueh pruefen statt spaet scheitern. Siehe troubleshooting.md, A.
# Regex-Muster liegen in Variablen: [[ =~ ]] erwartet sie UNquoted, sonst woertlicher Vergleich.
RE_HOST='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'   # RFC-1123-Label; wird auch Flake-Attribut .#<host>
RE_USER='^[a-z_][a-z0-9_-]{0,31}$'                        # POSIX-portabel; wird in Nix-Config + Pfade interpoliert
RE_LOC='^[a-z]{2,3}_[A-Z]{2}\.UTF-8(@[a-z]+)?$'           # glibc-Name sprache_LAND.UTF-8[@modifier]
RE_XKB='^[a-z]{2,3}(,[a-z]{2,3})*$'                       # kommagetrennte xkb-Codes

while :; do
  read -rp "Hostname [nixos]: " HOST; HOST="${HOST:-nixos}"
  [[ $HOST =~ $RE_HOST ]] && break
  echo "  Ungueltig. Erlaubt: Buchstaben/Ziffern/'-', 1-63 Zeichen, kein '-' am Anfang/Ende."
done
while :; do
  read -rp "Benutzername [user]: " USER_; USER_="${USER_:-user}"
  if [ "$USER_" = "root" ]; then echo "  'root' geht nicht (wird separat eingerichtet)."; continue; fi
  [[ $USER_ =~ $RE_USER ]] && break
  echo "  Ungueltig. Erlaubt: a-z/0-9/'_'/'-' (klein), Beginn mit Buchstabe oder '_', max. 32 Zeichen."
done
while :; do
  read -rp "Zeitzone [Europe/Berlin]: " TZ; TZ="${TZ:-Europe/Berlin}"
  if [ -e "/etc/zoneinfo/$TZ" ] || timedatectl list-timezones 2>/dev/null | grep -qx "$TZ"; then break; fi
  echo "  Unbekannte Zeitzone. Format Gebiet/Ort, z.B. Europe/Berlin (Liste: timedatectl list-timezones)."
done

echo
echo "Locale (Systemsprache/-formate):"
echo "  1) de_DE.UTF-8   (Deutsch)"
echo "  2) en_US.UTF-8   (Englisch US)"
echo "  3) en_GB.UTF-8   (Englisch UK)"
echo "  4) eigene        (glibc-Name, z.B. fr_FR.UTF-8)"
while :; do
  read -rp "Auswahl [1]: " LSEL; LSEL="${LSEL:-1}"
  case "$LSEL" in
    1) LOC="de_DE.UTF-8"; break ;;
    2) LOC="en_US.UTF-8"; break ;;
    3) LOC="en_GB.UTF-8"; break ;;
    4) while :; do
         read -rp "Locale: " LOC
         [[ $LOC =~ $RE_LOC ]] && break 2
         echo "  Ungueltiges Format. Erwartet sprache_LAND.UTF-8[@modifier], z.B. fr_FR.UTF-8."
       done ;;
    *) echo "  Bitte 1-4 waehlen." ;;
  esac
done

echo
echo "Tastaturlayout (xkb):"
echo "  1) de            (Deutsch)"
echo "  2) us            (Englisch US)"
echo "  3) gb            (Englisch UK)"
echo "  4) de,us         (Deutsch + Englisch-US, umschaltbar mit Alt+Shift)"
echo "  5) de,gb         (Deutsch + Englisch-UK, umschaltbar mit Alt+Shift)"
echo "  6) eigene        (kommagetrennte xkb-Codes, z.B. de,us,fr)"
while :; do
  read -rp "Auswahl [1]: " KB; KB="${KB:-1}"
  case "$KB" in
    1) XKB="de"; break ;;  2) XKB="us"; break ;;  3) XKB="gb"; break ;;
    4) XKB="de,us"; break ;;  5) XKB="de,gb"; break ;;
    6) while :; do
         read -rp "xkb-Layouts: " XKB; XKB="${XKB:-de}"
         [[ $XKB =~ $RE_XKB ]] && break 2
         echo "  Ungueltiges Format. Kommagetrennte xkb-Codes, z.B. de,us,fr."
       done ;;
    *) echo "  Bitte 1-6 waehlen." ;;
  esac
done

# Optional: generische Update-Erinnerung (Desktop-Icon + stuendlicher Notify-Timer + update-all.sh
# + fwupd fuer Firmware/BIOS). Erzeugt modules/host-updates.nix + update-all.sh und haengt das
# Modul in die Host-Config. Default J (Enter = installieren): Die Update-Mechanik gehoert zur
# Basis — der alte Default N wurde beim Durchklicken still uebersprungen (troubleshooting.md, D).
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
  echo "An vfio-pci binden spart im Leerlauf Strom (Slot wird stromlos), macht die GPU aber fuer den"
  echo "HOST unbrauchbar (kein CUDA, kein Host-Gaming — nur Passthrough an eine VM)."
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

cat > flake.nix <<EOF
{
  description = "NixOS - $HOST";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = { url = "github:nix-community/disko/latest"; inputs.nixpkgs.follows = "nixpkgs"; };
  };
  outputs = { self, nixpkgs, disko, ... }: {
    nixosConfigurations.$HOST = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        disko.nixosModules.disko
        ./hosts/$HOST/disk.nix
        ./hosts/$HOST/hardware-configuration.nix
        ./hosts/$HOST/configuration.nix
      ];
    };
  };
}
EOF

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

# ── Geteilter Desktop-Stack als generisches Modul (host-unabhaengig) ──────────
# Regionale Werte (Zeitzone/Locale/Tastatur) werden hier fixiert -> konsistent ueber
# alle Hosts. Spaeter aus jeder Host-Config importierbar (modulares Multi-Host-Setup).
mkdir -p modules
cat > modules/desktop.nix <<EOF
# modules/desktop.nix — geteilte Desktop-Basis (generisch, host-unabhaengig).
# Vom Installer erzeugt. Hostname/User/stateVersion stehen pro Host in hosts/<host>/.
{ pkgs, ... }:
{
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;   # ESP nicht mit alten Generationen volllaufen lassen
  boot.loader.efi.canTouchEfiVariables = true;
  boot.initrd.systemd.enable = true;
  boot.kernelPackages = pkgs.linuxPackages;

  hardware.enableRedistributableFirmware = true;   # WLAN-/GPU-Firmware
  hardware.graphics.enable = true;                 # iGPU / Desktop
  zramSwap.enable = true;                          # komprimierter RAM-Swap (hibernate-sicher)
  # CPU-Microcode (intel/amd) setzt hardware-configuration.nix automatisch passend.

  networking.networkmanager.enable = true;

  time.timeZone = "$TZ";
  i18n.defaultLocale = "$LOC";
  services.xserver.xkb.layout = "$XKB";
$XKBOPT
  console.useXkbConfig = true;

  services.xserver.enable = true;
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  environment.systemPackages = with pkgs; [ vim git ];
}
EOF

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
# nachziehen mit 'bash usbguard-sync.sh --init' aus dem Referenz-Repo.
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
  # Datei (Workflow: usbguard-sync.sh; Doku: README-hardening.md im Referenz-Repo).
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
{ ... }:
{
  imports = [
$IMPORTS
  ];

  networking.hostName = "$HOST";
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

# ── Optional: Update-Erinnerung (Icon + stuendlicher Check) + update-all.sh ──────
# Nur wenn oben danach gefragt wurde. host-updates.nix ist generisch (haengt nur am Repo
# unter ~/nixos-config) und wurde bereits in die Host-Config eingehaengt (IMPORTS).
if [ "$HOSTUPDATES" = "1" ]; then
cat > modules/host-updates.nix <<'NIXEOF'
# modules/host-updates.nix
# ─────────────────────────────────────────────────────────────────────────────
# Generische Host-Wartung: erinnert an neue nixpkgs-Staende, bietet einen
# Ein-Klick-Weg, alles zu aktualisieren, und bringt fwupd fuer Firmware/BIOS mit.
# Haengt NUR am Repo unter ~/nixos-config (kein dev-VM- oder Hardware-Bezug)
# -> jeder Host kann es einzeln importieren.
#
# Drei abgestimmte Teile: Erinnerung (stuendlicher User-Timer; Snooze = Timer stoppen
# + transienter systemd-Wecker, KEIN State-File) -> Knopf (Desktop-Icon) -> ein Befehl
# (update-all.sh: Flake bumpen + Host + alle VMs + Firmware).
# Bewusst KEIN system.autoUpgrade: nichts aktualisiert unbeaufsichtigt.
{ lib, pkgs, ... }:
let
  # GUI-Launcher fuer Updates: oeffnet konsole und laesst update-all.sh laufen (Fenster bleibt offen).
  # Wird vom Update-Icon UND von der "Jetzt aktualisieren"-Benachrichtigung aufgerufen.
  nixos-update-gui = pkgs.writeShellScriptBin "nixos-update-gui" ''
    exec konsole -e bash -lc 'cd "$HOME/nixos-config" && bash update-all.sh; echo; read -rp "Fertig — Enter schliesst das Fenster. "'
  '';

  # Hintergrund-Check: vergleicht den gepinnten nixpkgs-Stand (flake.lock) mit dem Upstream-Branch.
  # Gibt es Neues -> Desktop-Benachrichtigung mit Snooze-Knoepfen. Snooze laeuft rein ueber
  # systemd (Stunden-Timer stoppen + transienter --on-calendar-Wecker, kein State-File);
  # ein aktiver Snooze ist via 'systemctl --user list-timers' sichtbar.
  # Vom systemd-User-Timer (stuendlich) ausgeloest. Tut nichts ohne grafische Sitzung.
  nixos-update-check = pkgs.writeShellScript "nixos-update-check" ''
    set -uo pipefail
    # pkgs.systemd: systemd-run/systemctl fuer den Snooze-Wecker garantiert im PATH.
    export PATH=${lib.makeBinPath [ pkgs.git pkgs.jq pkgs.libnotify pkgs.coreutils pkgs.systemd ]}:/run/current-system/sw/bin:$PATH

    REPO="$HOME/nixos-config"
    LOCK="$REPO/flake.lock"
    [ -f "$LOCK" ] || exit 0
    # (Kein Snooze-Gate mehr: waehrend eines Snooze ist der Stunden-Timer selbst gestoppt,
    #  dieser Check laeuft dann schlicht nicht. Sichten/Aufheben: troubleshooting.md, D.)

    # Gepinnten nixpkgs-Branch aus flake.lock lesen (robust ueber den root-Input). Der Branch
    # aendert sich durch einen Bump nicht -> bleibt die richtige Quelle fuer den ls-remote unten.
    node=$(jq -r '.nodes.root.inputs.nixpkgs // "nixpkgs"' "$LOCK")
    ref=$(jq -r --arg n "$node" '.nodes[$n].original.ref // "nixos-26.05"' "$LOCK")

    # Vergleichsbasis ist der Stand des LAUFENDEN Systems (nixos-version), NICHT flake.lock auf der
    # Platte: ein halbfertiger 'nix flake update' (flake.lock gebumpt, aber Host noch nicht gebaut)
    # wuerde sonst faelschlich als "kein Update" gewertet -> die Erinnerung verstummt dauerhaft.
    # nixpkgsRevision = die nixpkgs-Revision, mit der der laufende Host gebaut wurde.
    localrev=$(nixos-version --json 2>/dev/null | jq -r '.nixpkgsRevision // ""')
    # Fallback nur, wenn nixos-version keine Revision liefert (z. B. dirty build): flake.lock auf
    # der Platte. Den verwaisten-Bump-Fall faengt dann update-all.sh per Rollback ab (Kombi-Loesung).
    [ -n "$localrev" ] || localrev=$(jq -r --arg n "$node" '.nodes[$n].locked.rev // ""' "$LOCK")
    [ -n "$localrev" ] || exit 0

    # Upstream-HEAD des Branches (leichtgewichtig; offline/Fehler/Timeout -> still raus).
    upstream=$(timeout 20 git ls-remote https://github.com/NixOS/nixpkgs "refs/heads/$ref" 2>/dev/null | cut -f1)
    [ -n "$upstream" ] || exit 0
    [ "$localrev" = "$upstream" ] && exit 0

    # Es gibt Neues -> benachrichtigen und bis zu 1 h auf eine Aktion warten.
    rc=0
    choice=$(timeout 3600 notify-send \
      --app-name="NixOS" --icon=system-software-update --urgency=normal --expire-time=0 \
      --action=now="Jetzt aktualisieren" \
      --action=1h="In 1 Stunde" \
      --action=8h="In 8 Stunden" \
      --action=1d="Morgen" \
      "NixOS-Updates verfuegbar" \
      "Der nixpkgs-Kanal ($ref) ist weitergewandert. Jetzt aktualisieren oder spaeter erinnern lassen." \
      2>/dev/null) || rc=$?

    # rc=124 -> Timeout: niemand hat reagiert -> NICHTS tun; der Stunden-Timer laeuft weiter
    #   und erinnert beim naechsten Takt erneut. (Frueher galt Timeout als "morgen" — zusammen
    #   mit der dann toten Zombie-Benachrichtigung, deren Klicks ins Leere laufen, die Ursache
    #   fuer tagelanges Schweigen.)
    # rc weder 0 noch 124 -> notify-send-Fehler (kein Daemon/keine GUI) -> ebenfalls nichts
    #   tun; der naechste Stundenlauf versucht es neu.
    [ "$rc" -eq 0 ] || exit 0

    # Snooze rein ueber systemd — fuer JEDE Dauer (1 h / 8 h / morgen) derselbe Weg, nur mit
    # anderer Weckzeit. Reihenfolge ist Wecker-FIRST: erst den transienten Wecker setzen,
    # ERST WENN das geklappt hat, den Stunden-Timer stoppen. Schlaegt systemd-run fehl,
    # bleibt der Timer an -> die Erinnerung kommt schlimmstenfalls zu frueh, nie gar nicht.
    # --on-calendar statt --on-active: die monotone Uhr steht im Suspend still — ein "+8 h"-
    #   Wecker wuerde um jede Deckel-zu-Zeit verrutschen. Kalender-Timer feuern nach dem
    #   Aufwachen sofort nach, wenn die Weckzeit im Schlaf verstrichen ist.
    # Reboot/Logout raeumt transiente User-Units ab; der Stunden-Timer startet beim naechsten
    #   Login via timers.target von selbst -> Snooze vergessen heisst nur "Erinnerung kommt
    #   zu frueh", nie "kommt nicht mehr" (gutartige Degradation).
    snooze() {
      wake=$(date -d "$1" '+%Y-%m-%d %H:%M:%S') || return 0
      systemctl --user stop nixos-update-snooze.timer 2>/dev/null || true   # Doppel-Snooze raeumen
      systemctl --user reset-failed nixos-update-snooze.service 2>/dev/null || true
      if systemd-run --user --collect --unit=nixos-update-snooze --on-calendar="$wake" \
           systemctl --user start nixos-update-check.timer nixos-update-check.service
      then
        systemctl --user stop nixos-update-check.timer
      fi
    }

    case "$choice" in
      now|*"Jetzt"*)    exec ${nixos-update-gui}/bin/nixos-update-gui ;;
      1h|*"1 Stunde"*)  snooze "+1 hour" ;;
      8h|*"8 Stunden"*) snooze "+8 hours" ;;
      1d|*"Morgen"*)    snooze "+24 hours" ;;
      *)                snooze "+24 hours" ;;   # aktiv weggewischt -> bewusst bis morgen
    esac
  '';
in
{
  environment.systemPackages = with pkgs; [
    libnotify          # notify-send im PATH (fuer Debugging; der Timer bringt es selbst mit)
    nvd                # lesbare Closure-Diffs; update-all.sh nutzt es (Fallback: nix store diff-closures)
    nixos-update-gui
    # Desktop-Icon: Update-Knopf -> oeffnet konsole und faehrt update-all.sh
    # (Flake bumpen + Host + alle konfigurierten VMs). sudo-Passwort gibst du im Terminal ein.
    (makeDesktopItem {
      name = "nixos-update-all";
      desktopName = "NixOS aktualisieren";
      comment = "Flake bumpen, Host und alle konfigurierten VMs neu bauen";
      exec = "nixos-update-gui";
      icon = "system-software-update";
      categories = [ "System" ];
      terminal = false;
    })
  ];

  # ===== Firmware/BIOS via LVFS (fwupd) =====
  # Daemon + fwupdmgr; Abschnitt 5 in update-all.sh nutzt das (pruefen -> [j/N]-Gate ->
  # anwenden; ein bestaetigtes BIOS-Update rebootet direkt). Generisch unbedenklich:
  # Geraete ohne LVFS-Angebot (z. B. Consumer-Boards der devstation) melden schlicht
  # nichts -> der Skript-Abschnitt ueberspringt dann still. Nebenwirkung: auch Plasma
  # Discover zeigt Firmware-Updates an. LVFS hinkt Dell gelegentlich eine Version
  # hinterher — bei Security-BIOS lohnt der Gegencheck auf dell.com.
  services.fwupd.enable = true;

  # ===== Update-Benachrichtigung (stuendlicher Check, Snooze, Desktop-Notification) =====
  # Bewusst KEIN system.autoUpgrade: nichts aktualisiert unbeaufsichtigt (insb. die VM darf das nie —
  # ein Redeploy killt eine laufende Zed-Sitzung). Stattdessen: erinnern -> du drueckst den Knopf.
  systemd.user.services.nixos-update-check = {
    description = "Auf NixOS-Updates pruefen und benachrichtigen (mit Snooze)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${nixos-update-check}";
    };
  };
  systemd.user.timers.nixos-update-check = {
    description = "Stuendlicher Check auf NixOS-Updates";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;            # verpasste Laeufe nach Aufwachen/Boot nachholen (= auch "beim Start")
      RandomizedDelaySec = "10m";
    };
  };
}
NIXEOF

# SNAPSHOT der kanonischen update-all.sh aus dem nixos-config-Repo (Stand 2026-07-13).
# Gepflegt wird das Skript DORT — bei inhaltlichen Aenderungen diesen Block nachziehen.
cat > update-all.sh <<'SHEOF'
#!/usr/bin/env bash
#
# update-all.sh — bumpt den Flake und aktualisiert ALLES auf einen Schlag:
#   1) nix flake update   (hebt nixpkgs & Co. -> neues Zed, Plasma, claude-code, Kernel …)
#   2) Host erst BAUEN (ohne Aktivierung) -> Paket-Diff zeigen -> nachfragen -> aktivieren
#      (bei 'n' oder Fehler wird der flake.lock-Bump verworfen -> kein Drift Repo <-> System)
#  2b) Smoke-Checks direkt nach der Aktivierung: systemd-Zustand + alle check-*.sh im
#      Repo-Root (warnen nur, brechen nie ab — Rollback bleibt bewusste Entscheidung)
#   3) jede konfigurierte VM neu deployen (alle vorhandenen deploy-*-vm.sh; fragt vorher)
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
# Jeder andere Lauf braucht ein interaktives Terminal — jeder Schritt hat sein [j/n]-Gate.
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
    -h|--help)   sed -n '2,23p' "$0"; exit 0 ;;
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
LOGFILE=""; SMOKE_WARN=0; DIFF_OUT=""; pre_failed=""
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
fi

# ---------------------------------------------------------------------------
# 3) VMs neu deployen — skaliert ueber die vorhandenen deploy-*-vm.sh
#    (aktuell dev-vm + browser-vm; ein kuenftiges deploy-ai-vm.sh laeuft automatisch mit)
# ---------------------------------------------------------------------------
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
    for s in "${vm_scripts[@]}"; do
      vm="${s#deploy-}"; vm="${vm%.sh}"          # deploy-dev-vm.sh -> dev-vm
      if [ "$DRY_RUN" -eq 0 ]; then
        read -rp "$(printf '\033[1;34m[?]\033[0m %s jetzt neu deployen? (laufende VM wird kurz gestoppt) [j/N]: ' "$vm")" ans || ans=""
        case "$ans" in [jJyY]*) ;; *) warn "  uebersprungen: $vm"; continue ;; esac
      fi
      info "Deploye ${vm} (bash ${s})…"
      if run bash "$s"; then
        ok "${vm} aktualisiert."
      else
        warn "${vm}: Deploy FEHLGESCHLAGEN — uebersprungen. Host-Update bleibt aktiv;"
        warn "       spaeter gezielt erneut:  bash ${s}"
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
  # Hostname in Betreff UND Body: der Diff ist HOST-spezifisch, das Repo traegt spaeter
  # auch die devstation. Fehlgeschlagene Laeufe committen nie -> dafuer ist das Session-Log da.
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
#    eine Version hinterher — bei Security-BIOS Gegencheck auf dell.com (aufbau.md).
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
[ -n "$LOGFILE" ] && info "Session-Log dieses Laufs: $LOGFILE"
ok "update-all fertig."
SHEOF
chmod +x update-all.sh
echo "  -> Update-Erinnerung + update-all.sh angelegt."
fi

# ── Optional: geteiltes vfio-Modul (dGPU-Passthrough -> D3cold im Leerlauf) ──────────────────────
# Nur wenn oben eine D3cold-faehige dGPU erkannt UND bestaetigt wurde. host.passthroughIds/-User
# stehen bereits in der Host-Config (VFIO_CONFIG oben); hier kommt das Modul dazu, das daraus die
# Bindung baut. Generisch & mischbar -> spaetere VMs koennen weitere IDs beitragen.
if [ "$VFIO_D3COLD" = "1" ]; then
cat > modules/vfio.nix <<'NIXEOF'
# modules/vfio.nix — geteiltes Passthrough-Modul (AUTO-GENERIERT, danach frei editierbar).
# Jede VM, die ein PCI-Geraet durchreicht, traegt nur ihre IDs zu host.passthroughIds bei
# (Listen mergen in NixOS automatisch). Daraus baut dieses Modul EINE vfio-pci-Bindung +
# IOMMU + libvirt. Aktiv nach 'nixos-rebuild switch' + REBOOT (Kernel-Parameter).
{ config, lib, ... }:
let
  cfg = config.host;
in
{
  options.host.passthroughIds = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "10de:25a9" "8086:7e40" ];
    description = "PCI vendor:device-IDs, die an vfio-pci gebunden werden (VM-Passthrough).";
  };

  options.host.passthroughUser = lib.mkOption {
    type = lib.types.str;
    default = "";
    example = "alice";
    description = "Optionaler Benutzer, der fuer sudo-loses virsh in die libvirtd-Gruppe kommt.";
  };

  config = lib.mkIf (cfg.passthroughIds != [ ]) (lib.mkMerge [
    {
      # intel_iommu/amd_iommu sind je auf der anderen Plattform ein No-op -> beide unbedingt
      # setzbar, keine CPU-Erkennung noetig.
      boot.kernelParams = [
        "intel_iommu=on"
        "amd_iommu=on"
        "iommu=pt"
        "vfio-pci.ids=${lib.concatStringsSep "," (lib.unique cfg.passthroughIds)}"
      ];
      # vfio frueh laden, damit das Binding VOR den normalen Treibern greift.
      boot.initrd.kernelModules = [ "vfio_pci" "vfio_iommu_type1" "vfio" ];
      # libvirt/KVM, um die durchgereichten Geraete in VMs zu nutzen.
      virtualisation.libvirtd.enable = true;
    }
    (lib.mkIf (cfg.passthroughUser != "") {
      users.users.${cfg.passthroughUser}.extraGroups = [ "libvirtd" ];
    })
  ]);
}
NIXEOF
echo "  -> modules/vfio.nix angelegt (dGPU an vfio-pci -> D3cold im Leerlauf)."
fi

# ── Optional: Host-Haertung nach BSI SYS.2.3 (modules/hardening.nix) ─────────────────
# Nur wenn oben danach gefragt wurde. Das Modul ist generisch; USBGuard aktiviert sich
# erst, wenn die Host-Config hardening.usbguard.rulesFile setzt (s. HARDENING_CONFIG oben).
if [ "$HARDENING" = "1" ]; then
cat > modules/hardening.nix <<'NIXEOF'
# modules/hardening.nix
# ─────────────────────────────────────────────────────────────────────────────
# Host-Haertung nach BSI IT-Grundschutz SYS.2.3 (Clients unter Linux und Unix),
# Zielbild: Basis + Standard + erhoehter Schutzbedarf (H) auf den PHYSISCHEN
# Arbeits-Maschinen (devbook, devstation). VMs importieren dieses Modul NICHT —
# sie sind selbst die kompensierende Massnahme (Isolation exponierter Workloads).
#
# Abdeckung (Details + Erlaeuterungstexte fuer den GSC: README-hardening.md):
#   A6  (S) Wechsellaufwerke: kein Automount-Zwang, udisks2 mountet noexec/nosuid/nodev
#   A8  (S) AppArmor aktiv (+ mitgelieferte Profile; Abdeckung ehrlich dokumentiert)
#   A11 (S) Ueberlauf-Schutz: nix-GC + min-free/max-free + journald-Deckel
#   A14 (H) USBGuard: Whitelist aus dem Repo (deklarativ = "zentral verwaltet")
#   A17 (H) via A8 + VM-Isolation (keine exponierten Host-Dienste; s. README)
#   A18 (H) sysctl-Haertung statt hardened Kernel (Begruendung: libvirt/VFIO-Rueckgrat)
#   A20 (H) SysRq auf 16 (nur Sync) — NixOS-Default, hier explizit/deterministisch
#
# BEWUSST NICHT umgesetzt (dokumentierte Abweichungen, s. README-hardening.md):
#   A15 (H) noexec auf /home — bricht Zed/Language-Server; Entwicklung laeuft in der dev-VM
#   linuxPackages_hardened — Konflikt-Risiko mit Virtualisierung/User-Namespaces
{ config, lib, pkgs, ... }:

let
  cfg = config.hardening;
in
{
  options.hardening = {
    usbguard.rulesFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Pfad zur gepinnten USBGuard-Regeldatei des Hosts (Ausgabe von
        `sudo usbguard generate-policy`, im Repo eingecheckt). null = USBGuard aus —
        konservativer Default, damit ein neuer Host ohne eigene Regelliste nicht
        versehentlich alle USB-Geraete blockt. Pro Host eine EIGENE Datei erzeugen
        (die Regeln tragen geraetespezifische Hashes/Ports).
      '';
      example = lib.literalExpression "./usbguard-rules.conf";
    };
  };

  config = {
    # ===== A6 — Wechsellaufwerke (S) ==========================================
    # Plasma mountet nicht automatisch (Geraete-Benachrichtigung = manueller Klick);
    # hier wird deklarativ festgeschrieben, WOMIT udisks2 mountet, wenn gemountet
    # wird: nie ausfuehrbar, nie setuid, keine Geraetedateien. Gilt fuer alle per
    # udisks eingebundenen Wechseldatentraeger (USB-Stick, SD-Karte, …).
    services.udisks2.settings."mount_options.conf".defaults = {
      defaults = "rw,nosuid,nodev,noexec";
    };

    # ===== A8 — AppArmor (S) ==================================================
    # Kernel-LSM aktiv + die in nixpkgs mitgelieferten Profile. Ehrlich: die
    # Profilabdeckung in nixpkgs ist duenn (deutlich unter Debian/Ubuntu-Niveau);
    # der eigentliche Schutz exponierter Workloads ist hier die VM-Grenze
    # (browser-VM/dev-VM), AppArmor ist die Zusatzschicht auf dem Host.
    # killUnconfinedConfinables bleibt AUS (konservativ: kein Abschiessen laufender
    # Prozesse beim Profil-Reload).
    security.apparmor = {
      enable = true;
      packages = [ pkgs.apparmor-profiles ];
      killUnconfinedConfinables = false;
    };

    # ===== A11 — Schutz vor Ueberlastung der Platte (S) =======================
    # Der realistische Vollaeufer auf NixOS ist /nix (ein btrfs-Pool, keine Quotas —
    # bewusste Entscheidung: qgroups kosten Pflege + Performance). Drei Deckel:
    #  1) woechentliche GC, Generationen aelter 14 Tage fallen weg
    #     (Rollback-Fenster bleibt 14 Tage; systemd-boot haelt ohnehin max. 10 Eintraege)
    #  2) min-free/max-free: laeuft der Store unter 2 GiB frei, raeumt Nix beim
    #     Bauen selbststaendig bis 8 GiB frei — faengt den Vollaeufer WAEHREND
    #     eines grossen Builds, wo der Wochen-Timer nicht hilft
    #  3) journald gedeckelt (Logs liegen auf dem eigenen Subvolume /var/log)
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
    nix.settings = {
      min-free = 2 * 1024 * 1024 * 1024;   # 2 GiB
      max-free = 8 * 1024 * 1024 * 1024;   # 8 GiB
    };
    services.journald.extraConfig = ''
      SystemMaxUse=1G
    '';

    # ===== A14 — USBGuard (H) =================================================
    # Whitelist = eingecheckte Regeldatei (Option oben) -> "zentral verwaltete
    # Whitelist" ist woertlich das Git-Repo. Neue Geraete: erst blocken lassen,
    # dann Regel nachziehen (Workflow: README-hardening.md).
    #   - implicitPolicyTarget block: alles ohne Regel wird blockiert
    #   - presentControllerPolicy keep: Controller beim Daemon-Start NIE
    #     deautorisieren (Lockout-Schutz)
    #   - IPC fuer wheel: 'usbguard list-devices' & Notifier ohne root
    services.usbguard = lib.mkIf (cfg.usbguard.rulesFile != null) {
      enable = true;
      ruleFile = cfg.usbguard.rulesFile;
      implicitPolicyTarget = "block";
      presentDevicePolicy = "apply-policy";
      insertedDevicePolicy = "apply-policy";
      presentControllerPolicy = "keep";
      IPCAllowedGroups = [ "wheel" ];
    };

    # Sichtbarkeitsschicht: Desktop-Benachrichtigung, sobald ein Geraet
    # erlaubt/geblockt wird (kein Management — Regeln kommen NUR aus dem Repo).
    systemd.user.services.usbguard-notifier = lib.mkIf (cfg.usbguard.rulesFile != null) {
      description = "USBGuard Desktop-Benachrichtigungen (allow/block-Ereignisse)";
      wantedBy = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.usbguard-notifier}/bin/usbguard-notifier";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # ===== A18 — Kernel-Haertung per sysctl (H) ===============================
    # Statt linuxPackages_hardened (Konflikt-Risiko mit libvirt/VFIO/User-Namespaces;
    # die BSI-Beispiele grsecurity/PaX sind seit 2017 nicht mehr frei verfuegbar).
    # User-Namespaces bleiben bewusst AN (Nix-Build-Sandbox braucht sie).
    boot.kernel.sysctl = {
      # A20: SysRq nur Sync (NixOS-Default — hier explizit, damit deterministisch)
      "kernel.sysrq" = 16;
      # Kernel-Adressen nicht an Userspace verraten (erschwert Exploit-Entwicklung)
      "kernel.kptr_restrict" = 2;
      # dmesg nur fuer root (Kernel-Log leakt Adressen/Hardware-Details)
      "kernel.dmesg_restrict" = 1;
      # BPF nur fuer privilegierte Prozesse + JIT-Haertung (haeufiger LPE-Vektor)
      "kernel.unprivileged_bpf_disabled" = 1;
      "net.core.bpf_jit_harden" = 2;
      # ptrace nur auf eigene Kindprozesse (yama) — bremst Credential-Harvesting
      "kernel.yama.ptrace_scope" = 1;
      # kexec aus: kein Laden eines Ersatz-Kernels zur Laufzeit (bis zum Reboot fix)
      "kernel.kexec_load_disabled" = 1;
      # keine Coredumps von setuid-Programmen
      "fs.suid_dumpable" = 0;
      # Link-/FIFO-Schutz in world-writable Verzeichnissen (haertet /tmp-Angriffe ab)
      "fs.protected_symlinks" = 1;
      "fs.protected_hardlinks" = 1;
      "fs.protected_fifos" = 2;
      "fs.protected_regular" = 2;
    };

    # ===== Deterministik: Firewall explizit an (NixOS-Default, festgeschrieben) =
    networking.firewall.enable = true;
  };
}
NIXEOF
echo "  -> modules/hardening.nix angelegt (SYS.2.3: AppArmor, USBGuard, sysctl, udisks2-noexec)."
fi


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
  echo "    Nachruesten ohne Neuinstallation: troubleshooting.md -> Abschnitt D."
fi
if [ "$HARDENING" = "1" ]; then
  if [ -f "hosts/$HOST/usbguard-rules.conf" ]; then
    echo "==> Haertung (SYS.2.3): INSTALLIERT — USBGuard aktiv ab dem ersten Boot."
    echo "    Verifikation nach dem Boot: usbguard list-devices --blocked  -> muss leer sein."
  else
    echo "==> Haertung (SYS.2.3): INSTALLIERT — USBGuard noch AUS (keine Whitelist erzeugt)."
    echo "    Nachziehen: bash usbguard-sync.sh --init  (Referenz-Repo, README-hardening.md)."
  fi
else
  echo "==> Haertung (SYS.2.3): UEBERSPRUNGEN (Prompt mit 'n' beantwortet)."
  echo "    Nachruesten: modules/hardening.nix aus dem Referenz-Repo + README-hardening.md."
fi
echo "==> Stick ziehen und 'sudo reboot'."
