# NixOS Installer

Interaktives Installationsskript für eine minimale, verschlüsselte NixOS-Basis. Das Skript fragt die maschinenspezifischen Werte ab, erkennt die Zielplatte selbst, erzeugt daraus ein Flake-Config-Repo unter `~/nixos-config` und installiert.

Es enthält keine persönlichen Daten und ist für beliebige Rechner geeignet.

## Was dabei herauskommt

- NixOS 26.05, Flake-basiert
- **Modular aufgebaut**: geteilter Desktop-/Basis-Stack in `modules/desktop.nix`, schlanke Host-Config je Rechner (importiert die Module, setzt nur Hostname + Benutzer)
- Vollverschlüsselt: LUKS2 auf der ganzen Platte, btrfs mit Subvolumes (`/`, `/home`, `/nix`, `/persist`, `/var/log`, zstd-komprimiert, noatime)
- systemd-boot (UEFI), systemd-Stage-1-initrd, LTS-Kernel
- KDE Plasma 6 (SDDM)
- Deklarativer Benutzer; die Passwort-Hashes liegen auf `/persist`, nicht im Repo
- **Optional**: Update-Erinnerung (Desktop-Icon + stündlicher Check auf neue nixpkgs-Stände, mit `update-all.sh` als Ein-Klick-Update)

Das ist bewusst eine minimale First-Boot-Basis. Härtung, VMs, Secure Boot mit eigenen Schlüsseln usw. baust du anschließend auf dieser Grundlage auf.

## Voraussetzungen

- NixOS-26.05-Minimal-ISO, im UEFI-Modus gebootet
- Secure Boot deaktiviert (die Installer-ISO ist nicht signiert)
- Netzwerk im Live-System (LAN, oder WLAN via `nmtui`)

## Benutzung

Im Live-Installer:

```bash
# Skript holen (curl ist im Installer i.d.R. vorhanden; sonst: nix-shell -p curl --run '...')
curl -O https://raw.githubusercontent.com/0xSprotti/nixos-installer/main/install.sh

# 1) Prüf-Lauf: erzeugt NUR die Config-Dateien, löscht NICHTS
bash install.sh --dry-run
#    -> danach ~/nixos-config ansehen und prüfen

# 2) Echter Lauf: partitioniert, verschlüsselt und installiert
bash install.sh
```

Fehlende Tools (`git`, `mkpasswd`, `pciutils`) holt sich das Skript selbst per `nix-shell` — du musst den Aufruf also nicht mehr darin verpacken.

Danach: Stick ziehen, `sudo reboot`.

> ℹ️ **Wenig RAM (< 12 GB):** Der Installer erkennt das automatisch und schont den Speicher beim Build — er lenkt das Build-Temp auf die frisch eingerichtete Platte (statt ins RAM-`tmpfs` des Live-Systems), legt für die Dauer der Installation eine temporäre Swap-Datei an und drosselt die Build-Parallelität (`max-jobs=1`, `cores=1`). Das verhindert Out-of-Memory-Abbrüche beim `nixos-install`, dauert dafür länger. Auf Maschinen mit genug RAM bleibt alles unverändert schnell.

## Was abgefragt bzw. erkannt wird

**Abgefragt:** Hostname, Benutzername, Zeitzone, Locale, Tastaturlayout (einzeln wie `de`/`us`/`gb` oder Kombination wie `de,us` — umschaltbar mit Alt+Shift) und ob eine optionale **Update-Erinnerung** eingerichtet werden soll.

**Automatisch erkannt:** alle internen Platten (USB-, Wechsel- und loop-Geräte werden ausgeblendet). Die stabile by-id wird in `disk.nix` gesetzt (nvme-eui/wwn bevorzugt). GPU- und WLAN-PCI-IDs landen zusätzlich in `hosts/<host>/DETECTED-HARDWARE.txt` als Referenz für spätere Schritte.

Bei genau einer Platte wird sie als Default angeboten (Enter genügt). Bei mehreren erscheint ein Menü mit den Layout-Modi (siehe unten).

## Mehrere Platten: Layout-Modi

Wird mehr als eine interne Platte erkannt, fragt der Installer nach einem Modus:

- **Eine Platte** (Standard, am besten getestet) — volles Layout auf einer gewählten Platte: GPT + ESP + LUKS2 + btrfs.
- **Pool** — mdadm-RAID0 über die gewählten Platten, darüber ein LUKS und ein btrfs. Mehr Kapazität, keine Redundanz (eine Platte fällt aus → alles weg).
- **Spiegel** — mdadm-RAID1. Übersteht den Ausfall einer Platte; nutzbarer Platz ≈ kleinste Platte.
- **Getrennte Rollen** — System (LUKS+btrfs) auf einer Platte, die übrigen je als separate verschlüsselte btrfs-Datenplatte unter `/data2`, `/data3`, …

Bei Pool/Spiegel liegt ein LUKS über dem RAID → eine Passphrase; die ESP (`/boot`) liegt auf der ersten Platte. mdadm-Assembly und initrd richtet disko automatisch ein. Bei Getrennten Rollen für alle Platten dieselbe Passphrase wählen — dann entsperrt systemd beim Boot meist mit einer einzigen Eingabe.

> ⚠️ **Experimentell:** Die Modi 2–4 sind nach den offiziellen disko-Beispielen gebaut, aber nicht auf echter Hardware getestet. Vor dem echten Lauf unbedingt `--dry-run` nutzen und die erzeugte `disk.nix` prüfen. Der Einzelplatten-Pfad (1) ist der erprobte Standard. mdadm-RAID1 bietet zudem keine btrfs-Prüfsummen-Selbstheilung — für reine Integrität ist eine Einzelplatte mit Backups oft die einfachere Wahl.

## ⚠️ Datenverlust & Sicherheit

- Der Installationsschritt **löscht die gewählte(n) Platte(n) vollständig**.
- Prüfe in der Zusammenfassung die Liste der Platten, die gelöscht werden (nicht den Installer-Stick!), bevor du `JA` tippst.
- Nutze zuerst `--dry-run` und sieh dir die erzeugte Config an.
- Im Repo liegen keine Geheimnisse — Passwort-Hashes werden zur Laufzeit erzeugt und nur auf `/persist` gespeichert.

## Erzeugte Struktur

```
~/nixos-config/
├── flake.nix
├── modules/
│   ├── desktop.nix                # geteilter Desktop-/Basis-Stack (Boot, Netz, Locale, KDE)
│   └── host-updates.nix           # nur mit Update-Erinnerung: Icon + stündlicher Notify-Timer
├── update-all.sh                  # nur mit Update-Erinnerung: flake.lock bumpen + Rebuild
└── hosts/<host>/
    ├── disk.nix                   # disko: GPT + LUKS2 + btrfs (je nach Platten-Modus)
    ├── configuration.nix          # schlank: importiert modules/, setzt Hostname + Benutzer
    ├── hardware-configuration.nix # live erzeugt
    └── DETECTED-HARDWARE.txt      # GPU/WLAN-IDs als Referenz (nicht aktiv)
```

Der geteilte Stack (Boot, Netzwerk, Locale, Tastatur, KDE, Basis-Pakete) liegt in `modules/desktop.nix`; die regionalen Werte (Zeitzone/Locale/Tastatur) sind dort aus den Abfragen fixiert. Die `hosts/<host>/configuration.nix` importiert dieses Modul und setzt nur das Maschinenspezifische (Hostname, Benutzer). So lassen sich später weitere Hosts anlegen, die denselben Desktop-Stack teilen.

## Weiterverwenden

Der Installer kopiert die erzeugte Config nach `/home/<user>/nixos-config` auf das installierte System — sie ist dort bereits ein Git-Repo (mit Initial-Commit). Nach dem ersten Boot verwaltest du das System von dort:

```bash
cd ~/nixos-config
sudo nixos-rebuild switch --flake .#<host>
```

Hast du die Update-Erinnerung gewählt, gibt es zusätzlich ein Desktop-Icon „NixOS aktualisieren" und `update-all.sh` (bumpt `flake.lock` und baut den Host neu) — ein stündlicher Timer meldet, wenn der nixpkgs-Kanal weitergewandert ist.

Zum Sichern/Versionieren ein eigenes (separates, ggf. privates) Remote hinzufügen und pushen:

```bash
git remote add origin https://github.com/<dein-user>/<dein-config-repo>.git
git push -u origin main
```

Dieses Installer-Repo und deine generierte Config sind getrennte Repos.

## Lizenz

Gemeinfrei (Public Domain), freigegeben über The Unlicense — siehe die Datei `UNLICENSE`. Du darfst den Code ohne Bedingungen kopieren, ändern, verwenden und verbreiten, kommerziell oder nicht.
