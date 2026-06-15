# NixOS Installer

Interaktives Installationsskript für eine minimale, verschlüsselte NixOS-Basis.
Das Skript fragt die maschinenspezifischen Werte ab, **erkennt die Zielplatte selbst**,
erzeugt daraus ein Flake-Config-Repo unter `~/nixos-config` und installiert.

Es enthält keine persönlichen Daten und ist für **beliebige Rechner** geeignet.

## Was dabei herauskommt

- NixOS 26.05, Flake-basiert
- Vollverschlüsselt: **LUKS2** auf der ganzen Platte, **btrfs** mit Subvolumes
  (`/`, `/home`, `/nix`, `/persist`, `/var/log`, zstd-komprimiert, `noatime`)
- **systemd-boot** (UEFI), systemd-Stage-1-initrd, **LTS-Kernel**
- **KDE Plasma 6** (SDDM)
- Deklarativer Benutzer; die Passwort-Hashes liegen auf `/persist`, **nicht im Repo**

Das ist bewusst eine **minimale First-Boot-Basis**. Härtung, VMs, Secure Boot mit
eigenen Schlüsseln usw. baust du anschließend auf dieser Grundlage auf.

## Voraussetzungen

- NixOS-26.05-**Minimal-ISO**, im **UEFI**-Modus gebootet
- **Secure Boot deaktiviert** (die Installer-ISO ist nicht signiert)
- Netzwerk im Live-System (LAN, oder WLAN via `nmtui`)

## Benutzung

Im Live-Installer:

```bash
# Skript holen (öffentlich, ohne Token)
nix-shell -p curl --run 'curl -O https://raw.githubusercontent.com/0xSprotti/nixos-installer/main/install.sh'

# 1) Prüf-Lauf: erzeugt NUR die Config-Dateien, löscht NICHTS
nix-shell -p git mkpasswd pciutils --run 'bash install.sh --dry-run'
#    -> danach ~/nixos-config ansehen und prüfen

# 2) Echter Lauf: partitioniert, verschlüsselt und installiert
nix-shell -p git mkpasswd pciutils --run 'bash install.sh'
```

Danach: Stick ziehen, `sudo reboot`.

## Was abgefragt bzw. erkannt wird

**Abgefragt:** Hostname, Benutzername, Zeitzone, Locale, Tastaturlayout
(einzeln wie `de`/`us`/`gb` oder Kombination wie `de,us` — umschaltbar mit Alt+Shift).

**Automatisch erkannt:** die Ziel-Platte (die stabile `by-id` wird in `disk.nix`
gesetzt, `nvme-eui`/`wwn` bevorzugt). GPU- und WLAN-PCI-IDs werden zusätzlich in
`hosts/<host>/DETECTED-HARDWARE.txt` als Referenz für spätere Schritte abgelegt.

## ⚠️ Datenverlust & Sicherheit

- Der Installationsschritt **löscht die gewählte Platte vollständig**.
- Prüfe in der Zusammenfassung, dass die `device`-Zeile wirklich deine **Zielplatte**
  ist (nicht der Installer-Stick), bevor du `JA` tippst.
- Nutze zuerst `--dry-run` und sieh dir die erzeugte Config an.
- Im Repo liegen **keine Geheimnisse** — Passwort-Hashes werden zur Laufzeit erzeugt
  und nur auf `/persist` gespeichert.

## Erzeugte Struktur

```text
~/nixos-config/
├── flake.nix
└── hosts/<host>/
    ├── disk.nix                  # disko: GPT + LUKS2 + btrfs (erkannte by-id)
    ├── configuration.nix         # Basis-System (Boot, Netz, Locale, KDE, Benutzer)
    ├── hardware-configuration.nix # live erzeugt
    └── DETECTED-HARDWARE.txt      # GPU/WLAN-IDs als Referenz (nicht aktiv)
```

## Weiterverwenden

Der Installer kopiert die erzeugte Config nach `/home/<user>/nixos-config` auf das
installierte System — sie ist dort bereits ein Git-Repo (mit Initial-Commit). Nach
dem ersten Boot verwaltest du das System von dort:

```bash
cd ~/nixos-config
sudo nixos-rebuild switch --flake .#<host>
```

Zum Sichern/Versionieren ein **eigenes** (separates, ggf. privates) Remote hinzufügen
und pushen:

```bash
git remote add origin https://github.com/<dein-user>/<dein-config-repo>.git
git push -u origin main
```

Dieses Installer-Repo und deine generierte Config sind getrennte Repos.

## Lizenz

Gemeinfrei (Public Domain), freigegeben über **The Unlicense** — siehe die Datei
[`UNLICENSE`](UNLICENSE). Du darfst den Code ohne Bedingungen kopieren, ändern,
verwenden und verbreiten, kommerziell oder nicht.
