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

# ===================== 2. Zielplatte erkennen =====================
echo
echo "Verfuegbare Datenträger (USB ausgeblendet):"
lsblk -dpno NAME,SIZE,MODEL,TRAN | grep -viE 'usb|loop' || true
echo "  (Falls deine Platte fehlt: in anderem Terminal 'lsblk' pruefen.)"
# Interne Platten als Auswahl-Kandidaten sammeln:
# TYPE=disk (also kein loop), nicht USB, nicht wechselbar.
DISK_CANDS=()
while read -r _name; do
  [ -n "$_name" ] || continue
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
cat <<SUMMARY

==================== Zusammenfassung ====================
  Hostname   : $HOST
  Benutzer   : $USER_
  Zeitzone   : $TZ
  Locale     : $LOC
  Tastatur   : $XKB    (mehrere Layouts: $MULTI)
  Layout     : $MODE_DESC
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

cat > "hosts/$HOST/configuration.nix" <<EOF
{ config, pkgs, ... }:
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

  networking.hostName = "$HOST";
  networking.networkmanager.enable = true;

  time.timeZone = "$TZ";
  i18n.defaultLocale = "$LOC";
  services.xserver.xkb.layout = "$XKB";
$XKBOPT
  console.useXkbConfig = true;

  services.xserver.enable = true;
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  users.users.$USER_ = {
    isNormalUser = true;
    description = "$USER_";
    extraGroups = [ "wheel" "networkmanager" ];
    hashedPasswordFile = "/persist/secrets/$USER_.hash";
  };
  users.users.root.hashedPasswordFile = "/persist/secrets/root.hash";

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  environment.systemPackages = with pkgs; [ vim git ];

  system.stateVersion = "26.05";
}
EOF

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
echo "==> Platte wird partitioniert/verschluesselt (disko fragt nochmal + LUKS-Passphrase)."
sudo nix --experimental-features "nix-command flakes" \
  run github:nix-community/disko/latest -- \
  --mode destroy,format,mount "./hosts/$HOST/disk.nix"

sudo nixos-generate-config --no-filesystems --root /mnt
sudo cp /mnt/etc/nixos/hardware-configuration.nix "hosts/$HOST/hardware-configuration.nix"

sudo mkdir -p /mnt/persist/secrets
echo "==> Passwort fuer Benutzer '$USER_':"
mkpasswd -m yescrypt | sudo tee "/mnt/persist/secrets/$USER_.hash" >/dev/null
echo "==> Passwort fuer 'root':"
mkpasswd -m yescrypt | sudo tee /mnt/persist/secrets/root.hash >/dev/null
sudo chmod 600 /mnt/persist/secrets/*.hash

git add -A
git -c user.email=installer@localhost -c user.name=installer commit -q -m "Initiale Config ($HOST)" || true
sudo env NIX_CONFIG="extra-experimental-features = nix-command flakes" \
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
echo "==> Stick ziehen und 'sudo reboot'."
