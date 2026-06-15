#!/usr/bin/env bash
#
# Generischer NixOS-First-Boot-Installer.
# Fragt Hostname/Benutzer/Tastatur ab, erkennt die Zielplatte, erzeugt das
# Config-Repo unter ~/nixos-config und installiert. Keine persoenlichen Daten im Skript.
#
# Pruef-Lauf (nur Dateien erzeugen, nichts loeschen):
#   nix-shell -p git mkpasswd pciutils --run 'bash install.sh --dry-run'
# Echter Lauf:
#   nix-shell -p git mkpasswd pciutils --run 'bash install.sh'
#
set -euo pipefail

usage() {
  cat <<'USAGE'
install.sh - generischer NixOS-First-Boot-Installer

  bash install.sh [--dry-run]

  --dry-run, -n   nur die Config-Dateien unter ~/nixos-config erzeugen,
                  nichts partitionieren / loeschen / installieren
  --help, -h      diese Hilfe

Benoetigt git, mkpasswd, pciutils, z.B.:
  nix-shell -p git mkpasswd pciutils --run 'bash install.sh --dry-run'
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
  command -v "$t" >/dev/null 2>&1 || { echo "FEHLER: '$t' fehlt - starte via: nix-shell -p git mkpasswd pciutils --run 'bash install.sh'" >&2; exit 1; }
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
lsblk -dpno NAME,SIZE,MODEL,TRAN | grep -vi usb || true
echo "  (Falls deine Platte fehlt: in anderem Terminal 'lsblk' pruefen.)"
read -rp "Ziel-Datenträger (z.B. /dev/nvme0n1) — WIRD VOLLSTAENDIG GELOESCHT: " DISK
[ -b "$DISK" ] || { echo "FEHLER: $DISK ist kein Blockgeraet." >&2; exit 1; }

# stabile by-id ermitteln (eui/wwn bevorzugt, sonst model-serial; ohne Partitionen)
BYID=""
for link in /dev/disk/by-id/*; do
  case "$link" in *-part*) continue ;; esac
  if [ "$(readlink -f "$link")" = "$(readlink -f "$DISK")" ]; then
    case "$link" in
      */nvme-eui.*|*/wwn-*) BYID="$link"; break ;;
      *) if [ -z "$BYID" ]; then BYID="$link"; fi ;;
    esac
  fi
done
if [ -z "$BYID" ]; then BYID="$DISK"; fi
echo "Stabile Kennung: $BYID"

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
  Zielplatte : $BYID
               -> $DISK   WIRD VOLLSTAENDIG GELOESCHT
  Modus      : $( [ "$DRY_RUN" = "1" ] && echo "DRY_RUN (nur Dateien)" || echo "ECHT (installiert)" )
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
    disko = { url = "github:nix-community/disko"; inputs.nixpkgs.follows = "nixpkgs"; };
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

cat > "hosts/$HOST/disk.nix" <<EOF
{
  disko.devices.disk.main = {
    type = "disk";
    device = "$BYID";
    content = {
      type = "gpt";
      partitions = {
        ESP = { priority = 1; size = "1G"; type = "EF00";
          content = { type = "filesystem"; format = "vfat"; mountpoint = "/boot"; mountOptions = [ "umask=0077" ]; }; };
        luks = { size = "100%";
          content = { type = "luks"; name = "cryptroot"; settings.allowDiscards = true;
            content = { type = "btrfs"; extraArgs = [ "-f" ];
              subvolumes = {
                "/root"    = { mountpoint = "/";        mountOptions = [ "compress=zstd" "noatime" ]; };
                "/home"    = { mountpoint = "/home";    mountOptions = [ "compress=zstd" "noatime" ]; };
                "/nix"     = { mountpoint = "/nix";     mountOptions = [ "compress=zstd" "noatime" ]; };
                "/persist" = { mountpoint = "/persist"; mountOptions = [ "compress=zstd" "noatime" ]; };
                "/log"     = { mountpoint = "/var/log"; mountOptions = [ "compress=zstd" "noatime" ]; };
              };
            };
          };
        };
      };
    };
  };
}
EOF

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
sudo nixos-install --flake ".#$HOST" --no-root-passwd

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
