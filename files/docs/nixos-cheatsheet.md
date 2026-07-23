# NixOS-Cheat-Sheet — Flake-Setup (Flotte)

> Schnellreferenz für den Alltag mit der NixOS-Config (Flake-basiert, Multi-Host).
> Dein Setup: Repo `~/nixos-config`, Host `<host>` (in den Beispielen durch deinen
> Rechnernamen ersetzen), dev-VM via libvirt,
> btrfs + LUKS + disko, Bootloader **systemd-boot** (kein GRUB).

---

## 0. Die goldene Regel (Flake + git)

Flakes bauen **nur aus git-getrackten Dateien**. Eine **neue, ungetrackte** Datei ist für den Build
unsichtbar — die Änderung wirkt dann scheinbar nicht.
```
git add -A          # vor JEDEM rebuild/deploy -- sonst greift deine Aenderung evtl. nicht
```
Die Warnung **„Git tree is dirty"** ist harmlos & erwartet (uncommittete, aber getrackte Änderungen).

---

## 1. Der tägliche Loop (ändern → bauen → versionieren)

```
cd ~/nixos-config
# ... Config editieren ...
git add -A
sudo nixos-rebuild switch --flake .#<host>    # atomar aktivieren
git commit -m "..."                            # versionieren (push optional)
```

---

## 2. Rebuild-Varianten (was wird wann aktiv?)

```
sudo nixos-rebuild switch --flake .#<host>    # bauen + SOFORT aktiv + Default beim Boot
sudo nixos-rebuild boot   --flake .#<host>    # bauen + erst beim NAECHSTEN Boot aktiv
sudo nixos-rebuild test   --flake .#<host>    # bauen + aktiv, aber NICHT ins Bootmenue (weg nach Reboot)
sudo nixos-rebuild build  --flake .#<host>    # nur bauen -> ./result, nichts aktivieren
sudo nixos-rebuild build-vm --flake .#<host>  # Config als Wegwerf-VM testen (./result/bin/run-*-vm)
```
`switch` ist der Alltag · `test` zum Ausprobieren (riskante Änderung überlebt keinen Reboot) ·
`boot` wenn etwas erst nach Neustart greifen soll (z. B. Kernel-Parameter).

---

## 3. Rückgängig / Generationen (das Sicherheitsnetz)

Jeder `switch` legt eine neue **Generation** an — du kommst jederzeit zurück.
```
sudo nixos-rebuild switch --rollback           # eine Generation zurueck (schnellster Weg)
nixos-rebuild list-generations                 # bequeme Uebersicht (neuere nixos-rebuild)
sudo nix-env -p /nix/var/nix/profiles/system --list-generations   # klassisch, immer da
```
Beim Booten: im **systemd-boot-Menü** eine ältere Generation wählen (Pfeiltasten).
Recovery, wenn nichts mehr bootet: ältere Generation starten → Config fixen → neu `switch`en.

---

## 4. Flake-Inputs aktualisieren (nixpkgs & Co. heben)

```
nix flake update                  # ALLE Inputs heben -> schreibt flake.lock neu
nix flake update nixpkgs          # nur einen Input heben
nix flake metadata                # was ist gepinnt? (Inputs + Revisionen)
git diff flake.lock               # was hat sich an den Pins geaendert?
```
Dein Komfort-Weg (Flake-Bump + Host + alle VMs auf einen Schlag):
```
bash update-all.sh                # fragt pro VM; committet flake.lock als DU
bash update-all.sh --host-only    # nur Flake + Host (VMs in Ruhe -> z.B. waehrend du in der dev-VM arbeitest)
bash update-all.sh --dry-run      # nur zeigen
```

---

## 5. dev-VM (libvirt/KVM)

```
bash deploy-dev-vm.sh                                  # bauen + (neu) deployen (Root frisch, /home/dev bleibt)
bash deploy-dev-vm.sh --ram 8192 --cpu 8 --disk 40G   # Ressourcen (kleben; Disk waechst nur)
bash deploy-dev-vm.sh --autostart                      # zusaetzlich: VM beim Host-Boot starten (Default: AUS)
bash deploy-dev-vm.sh --dry-run                        # Vorschau
```
libvirt direkt — `sudo virsh …` ODER ohne sudo per `virsh -c qemu:///system …` (dank libvirtd-Gruppe):
```
sudo virsh list --all             # welche VMs gibt es / laufen?
sudo virsh start dev-vm           # starten
sudo virsh shutdown dev-vm        # sauber herunterfahren
sudo virsh destroy dev-vm         # hart stoppen (wie Stecker ziehen)
sudo virsh console dev-vm         # serielle Konsole (Boot-Log/Login; raus: Strg-])
sudo virsh domifaddr dev-vm       # IP der VM
```
Boot-Autostart (reiner libvirt-State — `nixos-rebuild` / `flake update` fassen ihn NICHT an):
```
virsh -c qemu:///system autostart --disable dev-vm          # aus -> on-demand uebers Zed-Icon (Default)
virsh -c qemu:///system autostart           dev-vm          # an  -> VM startet beim Host-Boot
virsh -c qemu:///system dominfo  dev-vm | grep -i autostart # Status: enable / disable
```
> Damit `--disable` beim **Boot** auch greift, ist `onBoot = "ignore"` deklarativ gesetzt
> (`modules/dev-vm-host.nix`) — sonst belebt der `libvirt-guests`-Dienst eine beim Shutdown laufende
> VM wieder, trotz `autostart: disable` (Details: `README-deploy-dev-vm.md`). `--autostart` wirkt dabei weiter.

GUI der VM (Zed) auf dem Host: **Icon „Zed (dev-VM)"** — der Wrapper `zed-dev-vm-launch` fährt die VM
bei Bedarf hoch (kein Boot-Autostart), wartet auf SSH und startet Zed via `waypipe ssh -A dev@<ip> zed-dev`.
Erster Start nach dem Boot ~27 s; läuft die VM schon, kommt Zed sofort. Voraussetzung: `ssh-add` (sonst
fragt ksshaskpass grafisch).

---

## 6. Suchen (Pakete & Optionen)

```
nix search nixpkgs <begriff>      # Paket finden (z.B. nix search nixpkgs obsidian)
man configuration.nix             # alle NixOS-Optionen offline
```
Im Browser oft bequemer:
- Pakete: `https://search.nixos.org/packages`
- Optionen: `https://search.nixos.org/options` (z. B. `services.openssh.enable`)

---

## 7. Aufräumen (Plattenplatz / Store)

```
sudo nix-collect-garbage -d                        # ALTE Generationen + verwaisten Store-Muell loeschen
sudo nix-collect-garbage --delete-older-than 14d   # nur Generationen aelter als 14 Tage
nix store gc                                        # nur den Store aufraeumen (Generationen unangetastet)
df -h /                                             # wieviel Platz ist frei?
```
Nach `nix-collect-garbage -d` verschwinden alte **Bootmenü-Einträge** (Generationen weg). Der ESP-Füllstand
ist ohnehin via `boot.loader.systemd-boot.configurationLimit = 10` gedeckelt.
`result`-Symlink (vom `build`) wegräumen: `rm result` (ist in `.gitignore`).

---

## 8. Debugging (wenn was klemmt)

```
systemctl status <dienst>         # laeuft ein Dienst? warum nicht?
journalctl -u <dienst> -e         # Log eines Dienstes (ans Ende springen)
journalctl -b -p err              # Fehler seit dem letzten Boot
systemctl --user status <dienst>  # User-Dienste (z.B. dein nixos-update-check)
systemctl --user daemon-reload    # nach Aenderung an User-Units (oder ab-/anmelden)
sudo nixos-rebuild switch --flake .#<host> --show-trace   # ausfuehrlicher Build-Fehler
```

---

## 9. Wo liegt was?

| Datei                                      | Zweck                                          |
|--------------------------------------------|------------------------------------------------|
| `flake.nix`                                | Outputs (<host>, dev-vm, …); Inputs (nixpkgs)  |
| `flake.lock`                               | exakte Pins — via `nix flake update`           |
| `hosts/<host>/configuration.nix`          | Host-Config (Pakete, Dienste, Icons)           |
| `hosts/<host>/hardware-configuration.nix` | pro Gerät, von `nixos-generate-config` erzeugt |
| `hosts/<host>/disk.nix`                   | Platten-Layout (disko)                         |
| `hosts/dev-vm/configuration.nix`           | Gast-Config der dev-VM                         |
| `update-all.sh` / `deploy-dev-vm.sh`       | deine Wartungs-/Deploy-Skripte                 |

---

## 10. „Hilfe, …" — die häufigen Fälle

- **… meine Änderung wirkt nicht / „file not found" im Build:** neue Datei nicht getrackt →
  ```
  git add -A      # dann erneut rebuild
  ```
- **… rebuild bricht mit Assertion/Fehler ab:** Meldung lesen; oft eine entfernte/umbenannte Option
  (26.05 hat z. B. `virtualisation.libvirtd.qemu.ovmf` entfernt). Mit `--show-trace` mehr Details.
- **… System bootet nicht nach einem `switch`:** im systemd-boot-Menü die vorige Generation wählen,
  einloggen, Config fixen, neu `switch`en. (Oder zum Ausprobieren gleich `test` statt `switch`.)
- **… Platte voll:** `sudo nix-collect-garbage -d` (+ `df -h /` zum Gegenchecken).
- **… welche Generation lief gestern noch?** `nixos-rebuild list-generations`.
- **… was würde ein Update ändern?** `nix flake update && git diff flake.lock` (dann erst rebuild).

---

## 11. dGPU (RTX 2050): NVIDIA + PRIME Offload + RTD3

Arbeitsteilung seit 2026-07-16: Desktop & Apps laufen auf der
Arc-iGPU; die dGPU haengt am NVIDIA-Treiber, schlaeft in **D3cold** und wacht nur auf Anforderung:

```
nvidia-offload <programm>                            # Programm gezielt auf der dGPU starten
nvidia-smi                                           # Treiber-/GPU-Status (ACHTUNG: weckt die Karte)
cat /sys/bus/pci/devices/0000:01:00.0/power_state    # D3cold = schlaeft, D0 = aktiv
sudo cat /proc/driver/nvidia/gpus/0000:01:00.0/power # Treiber-Sicht: Runtime D3, Video Memory off
```

Steam: pro Spiel **Eigenschaften → Startoptionen** → `nvidia-offload %command%`
(Steam-Client & Downloads laufen auf der iGPU und halten die dGPU NICHT wach — verifiziert).

Render-Offload-Test (glxinfo heisst im nixpkgs jetzt mesa-demos):
```
nvidia-offload nix shell nixpkgs#mesa-demos --command glxinfo -B | grep -i renderer
```

Stolpersteine: Direkt nach dem Login kann die Karte noch ~1 min in D0 stehen (Runtime-PM greift
verzoegert — erst dann messen). In D3cold verschwindet die HDMI-Audio-Funktion (01:00.1) komplett
vom PCI-Bus — normal, kein Fehler. Bleibt sie dauerhaft in D0: `troubleshooting.md`, Abschnitt E.

---

## 12. VM-Netz-Isolation (nftables)

Seit 2026-07-21 (`modules/vm-net-isolation.nix`): browser-VM nur Internet
(80/443 + QUIC), dev-VM nur 22/443, Inter-VM verboten, VM→Host nur DNS/DHCP zur Bridge-`.1`.

```
sudo nft list table inet vm-isolation                # Regel-Inventur + Drop-Counter (GSC-Nachweis)
sudo nft list ruleset | less                         # Gesamtbild inkl. libvirt- und nixos-fw-Tabellen
```

Schnellproben (vom Host aus in die VMs; Soll-Matrix komplett in `README-hardening.md`):

```
ssh dev@192.168.243.2    'curl -m5 -s https://example.com >/dev/null && echo NETZ-OK'
ssh dev@192.168.243.2    'ping -c1 -W2 <lan-gateway> || echo LAN-DICHT'          # FAIL ist das Soll
ssh browse@192.168.244.2 'ping -c1 -W2 192.168.243.2 || echo INTER-VM-DICHT' # FAIL ist das Soll
```

Neuer Egress-Port noetig? **Dokumentierte Ausnahme** im Host-Ordner (nie im Modul):
`hardening.vmNetIsolation.devVm.allowedTcpPorts = [ 22 443 <port> ];` + Kommentar wozu.
Gast meldet NTP-Timeouts? Kosmetik — Uhr kommt via kvm-clock vom Host (`troubleshooting.md` §F).
Rollback: `hardening.vmNetIsolation.enable = false;` + rebuild (oder vorherige Generation booten).

---

## 13. Options-Prioritäten: mkDefault / normal / mkForce

Jede Options-Definition trägt eine **Priorität als Zahl — die niedrigere Zahl gewinnt**
(wie eine Rangliste: Platz 50 schlägt Platz 100):

| Schreibweise                        | Priorität | Bedeutung                                            |
|-------------------------------------|-----------|------------------------------------------------------|
| `option = lib.mkDefault wert;`      | 1000      | „nur falls niemand sonst etwas sagt" (Modul-Default) |
| `option = wert;`                    | 100       | normale Definition                                   |
| `option = lib.mkForce wert;`        | 50        | „gewinnt gegen normale Definitionen"                 |

**Wann braucht man mkForce?** Nur bei einem **Definitionskonflikt**: definieren zwei Stellen
(z. B. `modules/desktop.nix` und `hosts/<host>/configuration.nix`) dieselbe nicht-mergefähige
Option mit normaler Priorität, bricht der Build mit
`The option '…' is defined multiple times while it's expected to be unique` ab — und nennt
beide Fundstellen. `lib.mkForce` an der Host-Zeile löst das Patt (50 < 100).

```nix
# hosts/<host>/configuration.nix — Host uebersteuert eine NORMAL definierte Fleet-Invariante:
services.xserver.enable = lib.mkForce false;            # Beispiel: Headless-Sonderfall
```

Merksatz: **„mkForce drängelt sich vor — kleinere Zahl, vorderer Platz."** Es ändert nichts am
Wert, nur am Vorfahrtsrecht — und ein mkForce mit **demselben** Wert wie das Modul ist ein
No-op, das nur den selbstverursachten Konflikt auflöst (so geschah es beim L16-Kernel-Test
gegen die damals normal definierte Modul-Zeile, s. `troubleshooting.md` J).

**Drei-Ebenen-Design-Regel im Repo** (seit dem mkDefault-Umbau von `modules/desktop.nix`):

1. **Personalisierbare Vorschlagswerte** stehen im Modul mit `mkDefault` (1000) — Locale,
   Zeitzone, Tastatur, Kernelwahl. Der Host (bzw. der Installer mit deinen Prompt-Antworten)
   übersteuert mit **normaler Zuweisung** — kein mkForce nötig:
   `boot.kernelPackages = pkgs.linuxPackages;   # z. B. zurück auf LTS, nur dieser Host`
2. **Fleet-Invarianten** stehen im Modul **normal** (100) — Bootloader, Plasma, Unfree-Liste.
   Ein Host weicht nur mit explizitem `mkForce` ab: die Hürde ist Absicht.
3. **mkForce im Modul: nie** — es nähme jedem Host die Übersteuerungsmöglichkeit. Zwei Stolpersteine dazu: `lib` und `pkgs` müssen im Funktionskopf
der Datei stehen (`{ pkgs, lib, ... }:`), sonst `undefined variable`; und Kernel-Begriffe:
`pkgs.linuxPackages` = **LTS** (NixOS-Default), `pkgs.linuxPackages_latest` = **Mainline**
(neueste stabile Kernel-Serie im gepinnten nixpkgs-Stand).

---

## Mini-Glossar

- **Generation** = ein Snapshot deines Systemzustands. Jeder `switch` legt eine neue an; rollback jederzeit.
- **Flake** = reproduzierbare Einheit mit gepinnten Inputs (`flake.lock`). `.#<host>` = ein Output daraus.
- **Closure** = ein Paket samt **aller** Abhängigkeiten (das, was wirklich im Store landet).
- **Derivation** = die Bauanleitung für ein Paket (Nix wertet sie aus → baut → Store-Pfad).
- **Store** (`/nix/store`) = unveränderliche, gehashte Paket-Ablage; via garbage-collect aufgeräumt.
- **switch / boot / test** = sofort + dauerhaft · erst beim Boot · sofort aber flüchtig.
