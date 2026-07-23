# NixOS Installer

Interaktives Installationsskript für eine minimale, verschlüsselte NixOS-Basis. Das Skript fragt die maschinenspezifischen Werte ab, erkennt die Zielplatte selbst, erzeugt daraus ein Flake-Config-Repo unter `~/nixos-config` und installiert.

Es enthält keine persönlichen Daten und ist für beliebige Rechner geeignet. Die geteilten
Dateien des erzeugten Repos (Module, `update-all.sh`, Werkzeuge, Doku, `flake.nix`) kommen
als **Basis-Payload** aus dem `files/`-Verzeichnis dieses Repos mit — deshalb wird das
Installer-Repo **komplett geklont**, nicht nur `install.sh` heruntergeladen.

## Was dabei herauskommt

- NixOS 26.05, Flake-basiert
- **Modular aufgebaut**: geteilter Desktop-/Basis-Stack in `modules/desktop.nix` (regionale
  Werte und Kernel dort als `mkDefault`-Vorschläge), schlanke Host-Config je Rechner
  (importiert die Module, setzt Hostname + Benutzer + deine Prompt-Antworten als Overrides)
- Vollverschlüsselt: LUKS2 auf der ganzen Platte, btrfs mit Subvolumes (`/`, `/home`, `/nix`, `/persist`, `/var/log`, zstd-komprimiert, noatime)
- systemd-boot (UEFI), systemd-Stage-1-initrd; Kernel: **Mainline (latest)** als
  Flotten-Vorschlagswert (per Prompt auf LTS umstellbar — landet dann als normaler
  Host-Override in deiner Config, Hintergrund in `docs/troubleshooting.md`, J)
- KDE Plasma 6 (SDDM)
- Deklarativer Benutzer; die Passwort-Hashes liegen auf `/persist`, nicht im Repo
- **Optional**: Update-Erinnerung — Desktop-Icon + stündlicher Check auf neue nixpkgs-Stände (zurückstellbar um 1 h / 8 h / bis morgen), dazu `update-all.sh` als Ein-Klick-Update mit Paket-Diff (`nvd`), Session-Log, Smoke-Checks und Firmware/BIOS-Updates via fwupd (LVFS) — und **zentralen Datei-Updates** über den
  Payload-Mechanismus (`payload-sources.conf` + Abschnitt 0b, s. u.)
- **Optional**: Wird eine D3cold-fähige dedizierte GPU erkannt, kann sie auf Wunsch per vfio-pci gebunden werden. Im Leerlauf fällt sie dann in echtes **D3cold** (Slot stromlos) — auf Hybrid-Laptops spart das spürbar Strom, weil der Desktop ohnehin auf der iGPU läuft. Die dGPU steht danach nur noch für **VM-Passthrough** bereit, nicht mehr dem Host (kein CUDA/Host-Gaming).
- **Optional**: Host-Härtung nach **BSI IT-Grundschutz SYS.2.3** (Standard: Ja) — AppArmor, sysctl-Kernel-Härtung, `noexec/nosuid/nodev` für Wechselmedien, GC-/Log-Deckel und **USBGuard** mit einer aus dem Live-System erzeugten Geräte-Whitelist (alles andere wird geblockt, aktiv ab dem ersten Boot). Schlägt die Whitelist-Erzeugung fehl (z. B. offline), bleibt das Härtungsmodul installiert und nur USBGuard aus — nachrüstbar per `usbguard-sync.sh --init` (liegt bereits im Repo).

- **Immer dabei** (unabhängig von den Prompts): der komplette Basis-Payload aus `files/` —
  alle Module, `update-all.sh`, `usbguard-sync.sh`/`check-usbguard.sh`, `check-vfio.sh`, die
  Auto-Discovery-`flake.nix` und die gesamte Doku unter `docs/`. Module sind Infrastruktur;
  **wirken** tun sie erst über die Import-Entscheidungen der Prompts. Dazu
  `payload-sources.conf`, die das Repo mit künftigen zentralen Updates verbindet.

Das ist bewusst eine minimale First-Boot-Basis (auf Wunsch bereits SYS.2.3-gehärtet). VMs, Secure Boot mit eigenen Schlüsseln usw. baust du anschließend auf dieser Grundlage auf.

## Voraussetzungen

- NixOS-26.05-Minimal-ISO, im UEFI-Modus gebootet
- Secure Boot deaktiviert (die Installer-ISO ist nicht signiert)
- Netzwerk im Live-System (LAN, oder WLAN via `nmtui`)

## Benutzung

Im Live-Installer:

```bash
# Repo KOMPLETT klonen — install.sh braucht den files/-Payload daneben.
# (Ein Einzeldatei-Download bricht früh mit einer klaren Meldung ab.)
nix-shell -p git --run 'git clone https://github.com/0xSprotti/nixos-installer.git'
cd nixos-installer

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

**Abgefragt:** Hostname, Benutzername, Zeitzone, Locale, Tastaturlayout (einzeln wie `de`/`us`/`gb` oder Kombination wie `de,us` — umschaltbar mit Alt+Shift), ob eine optionale **Update-Erinnerung** eingerichtet werden soll (Standard: Ja — Enter genügt), ob die **Host-Härtung nach SYS.2.3** eingerichtet werden soll (Standard: Ja — Enter genügt) und — nur falls eine D3cold-fähige dedizierte GPU gefunden wurde — ob diese per **vfio-pci** gebunden werden soll.

**Automatisch erkannt:** alle internen Platten (USB-, Wechsel- und loop-Geräte werden ausgeblendet). Die stabile by-id wird in `disk.nix` gesetzt (nvme-eui/wwn bevorzugt). Außerdem sucht der Installer **vendor-unabhängig** nach einer dedizierten GPU, deren PCIe-Parent-Port eine ACPI-`_PR3`-Power-Resource hat (Bedingung für echtes D3cold) — die primäre Display-GPU (`boot_vga`) bleibt dabei stets ausgenommen. Wird eine solche dGPU gefunden, folgt die vfio-Abfrage oben; sonst erscheint sie gar nicht. Alle GPU- und WLAN-PCI-IDs landen zusätzlich in `hosts/<host>/DETECTED-HARDWARE.txt` als Referenz für spätere Schritte.

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
- Wählst du die vfio-Bindung, wird die dedizierte GPU dem **Host entzogen** (treiberlos an `vfio-pci` gebunden) — nutzbar dann nur per VM-Passthrough. Die Zusammenfassung zeigt das vor dem `JA` an; im Zweifel ablehnen, das Binding lässt sich später jederzeit in der Config nachrüsten. Ob `_PR3` im Live-ISO sichtbar ist, lässt sich vorab mit `--dry-run` prüfen.

## Erzeugte Struktur

```
~/nixos-config/
├── flake.nix                      # Auto-Discovery: findet Hosts + spätere VM-Gäste von selbst
├── payload-sources.conf           # Quellen für zentrale Updates (update-all.sh, Abschnitt 0b)
├── update-all.sh                  # Ein-Klick-Update: Payload → Flake → Diff → Host → Firmware
├── usbguard-sync.sh / check-usbguard.sh / check-vfio.sh
├── modules/                       # IMMER vorhanden — wirken erst über die Import-Prompts
│   ├── desktop.nix                # Basis-Stack; Locale/Tastatur/Kernel als mkDefault-Vorschläge
│   ├── host-updates.nix           # Update-Erinnerung: Icon + Notify-Timer (Snooze) + fwupd/LVFS
│   ├── hardening.nix              # SYS.2.3: AppArmor, USBGuard, sysctl, udisks2-noexec, GC-Deckel
│   └── vfio.nix                   # dGPU→vfio-pci (ohne host.passthroughIds ein reiner No-op)
├── docs/                          # komplette Doku: Payload, Härtung, Troubleshooting, Cheatsheets
└── hosts/<host>/
    ├── configuration.nix          # Hostname, Benutzer, deine Prompt-Overrides, Imports
    ├── disk.nix                   # disko: GPT + LUKS2 + btrfs (je nach Platten-Modus)
    ├── usbguard-rules.conf        # nur mit Härtung: gepinnte Whitelist (aus dem Live-System)
    ├── hardware-configuration.nix # live erzeugt
    └── DETECTED-HARDWARE.txt      # GPU/WLAN-IDs als Referenz (nicht aktiv)
```

Der geteilte Stack liegt in `modules/desktop.nix` — Zeitzone, Locale, Tastatur und Kernel
stehen dort als **mkDefault-Vorschläge**; deine Prompt-Antworten landen als normale
Zuweisungen in `hosts/<host>/configuration.nix` und übersteuern sie ohne `mkForce`
(Drei-Ebenen-Regel: `docs/nixos-cheatsheet.md`, §13). Weitere Hosts sind ein Ordner
`hosts/<name>/` mit den drei Dateien — die Auto-Discovery-`flake.nix` findet sie von
selbst. `modules/vfio.nix` ist generisch und mischbar — spätere VMs tragen eigene IDs bei.

## Weiterverwenden

Der Installer kopiert die erzeugte Config nach `/home/<user>/nixos-config` auf das installierte System — sie ist dort bereits ein Git-Repo (mit Initial-Commit). Nach dem ersten Boot verwaltest du das System von dort:

```bash
cd ~/nixos-config
sudo nixos-rebuild switch --flake .#<host>
```

### Zentrale Updates (Payload)

Die geteilten Dateien werden zentral gepflegt: `bash update-all.sh` prüft **ganz am
Anfang** (Abschnitt 0b) die Quellen aus `payload-sources.conf`, zeigt den Diff und
übernimmt erst nach deinem `[J/n]` — mit Provenienz-Commit
(`git log --oneline --grep=payload` als Chronik). Versions-Pinning (`#tag`) und interne
Spiegel sind eine Zeilen-Änderung; Zonen-Modell, bewusstes Abweichen und alle Details:
`docs/README-payload.md`. Kostenpflichtige **Extensions** (z. B. die VM-Suite) kommen nach
demselben Muster als zweite Quelle dazu (README-payload, §6).

Hast du die Update-Erinnerung gewählt, gibt es zusätzlich ein Desktop-Icon „NixOS aktualisieren" und `update-all.sh`:

```bash
bash update-all.sh              # Flake bumpen → Diff zeigen → Host aktivieren → Firmware
bash update-all.sh --host-only  # nur Flake + Host (keine VMs, keine Firmware → kein Reboot-Risiko)
bash update-all.sh --dry-run    # nur zeigen, was passieren würde; einziger Modus ohne TTY
```

Das Skript baut den neuen Stand erst **ohne Aktivierung**, zeigt den Paket-Diff (`nvd`) und fragt dann. Bei „n" oder Fehler wird der `flake.lock`-Bump verworfen — Repo und laufendes System bleiben deckungsgleich, und die stündliche Erinnerung (Vergleich: laufender Stand via `nixos-version` gegen Upstream) bleibt auch nach einem unterbrochenen Lauf zuverlässig. Erinnerungen lassen sich um 1 h / 8 h / bis morgen zurückstellen — als reine systemd-Timer übersteht das auch Suspend.

Nach der Aktivierung laufen **Smoke-Checks**: der systemd-Zustand wird geprüft, und eigene `check-*.sh` im Repo-Root werden automatisch mit ausgeführt — sie warnen nur und brechen nie ab. Der `flake.lock`-Commit trägt den Paket-Diff im Body: `git log -- flake.lock` wird so zur Update-Chronik. Jeder Lauf (außer `--dry-run`) landet komplett in einem Session-Log unter `~/.local/state/update-all/` (die letzten 20 bleiben liegen). Legst du später eigene `deploy-*-vm.sh` an, nimmt das Skript auch sie automatisch mit.

> ⚠️ **Firmware/BIOS:** Zum Schluss prüft `update-all.sh` via fwupd (LVFS) auf Firmware-Updates — mit eigenem `[j/N]`-Gate, denn ein bestätigtes BIOS-Update **rebootet sofort**. Mit `--host-only` bleibt dieser Teil komplett außen vor.

Hast du die vfio-Bindung gewählt, greift sie nach dem **nächsten Reboot** (Kernel-Parameter); danach hängt die dGPU an `vfio-pci` und fällt im Leerlauf in D3cold. Prüfen mit `lspci -nnk -d <vendor:device>` (erwartet: `Kernel driver in use: vfio-pci`).

Hast du die Härtung gewählt, ist sie ab dem ersten Boot aktiv. Kurz-Verifikation: `usbguard list-devices --blocked` muss **leer** sein (sonst wurde ein internes Gerät nicht erfasst — Regel nachziehen), `sudo aa-status` zeigt geladene AppArmor-Profile, und ein gemounteter USB-Stick trägt `noexec` (`findmnt /run/media/$USER/*`). Neue USB-Geräte werden per Default **geblockt** und am Desktop gemeldet; dauerhaft erlauben über die versionierte Whitelist `hosts/<host>/usbguard-rules.conf` (Workflow und Details: `usbguard-sync.sh` und `docs/README-hardening.md` — beides liegt im Repo). Meldet der Installer, dass die Whitelist nicht erzeugt werden konnte, ist USBGuard aus — nachrüsten mit `bash usbguard-sync.sh --init` und anschließendem Rebuild.

Zum Sichern/Versionieren ein eigenes (separates, ggf. privates) Remote hinzufügen und pushen:

```bash
git remote add origin https://github.com/<dein-user>/<dein-config-repo>.git
git push -u origin main
```

Dieses Installer-Repo und deine generierte Config sind getrennte Repos.

## Lizenz

Gemeinfrei (Public Domain), freigegeben über The Unlicense — siehe die Datei `UNLICENSE`. Du darfst den Code ohne Bedingungen kopieren, ändern, verwenden und verbreiten, kommerziell oder nicht.
