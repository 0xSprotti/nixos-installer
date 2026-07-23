# check-vfio.sh — Smoke-Check: vfio-Bindung intakt?

**Zweck:** Nach einem (Kernel-)Update prüfen, ob alle für Passthrough deklarierten PCI-Geräte noch
an `vfio-pci` hängen. Der klassische Bruch: ein Kernel-Update ändert die Treiber-Bindung, und der
gerissene GPU-Passthrough fällt erst beim nächsten VM-Start als verwirrender Fehler auf — dieser
Check zieht das auf den Moment direkt nach dem Update vor.

## Aufruf

```bash
bash check-vfio.sh   # manuell; läuft sonst automatisch in update-all.sh (Abschnitt 2b)
```

Kein sudo nötig, keine Flags.

## Funktionsweise

1. Liest `vfio-pci.ids=…` aus `/proc/cmdline` — das ist exakt, was `modules/vfio.nix` über
   `boot.kernelParams` deklariert. Keine zweite Wahrheit, kein Nix-Parsing.
2. Sucht je `vendor:device`-ID die Geräte über **sysfs**
   (`/sys/bus/pci/devices/*/vendor` + `device`) und prüft den `driver`-Symlink auf `vfio-pci`.

Bewusst reines sysfs statt `lspci`: keine Abhängigkeit von `pciutils`, läuft auf jedem Host.

## Exit-Semantik (selbst-guardend)

- `0` — alle deklarierten Geräte korrekt gebunden **oder** der Host deklariert gar kein
  Passthrough (dann still — „nicht zuständig")
- `1` — mindestens ein Gerät falsch gebunden oder nicht gefunden → `update-all.sh` warnt,
  bricht aber nicht ab

## Beispielausgabe

```
[check-vfio] 10de:25a2 (0000:01:00.0): an vfio-pci gebunden — OK
[check-vfio] WARNUNG: 10de:2291 (0000:01:00.1) haengt an "snd_hda_intel" statt vfio-pci — Passthrough gerissen?
```

## Wenn es warnt

1. Kernel-Parameter überhaupt da? `tr ' ' '\n' </proc/cmdline | grep vfio`
2. Nach Änderungen an `host.passthroughIds` bindet erst ein **Reboot** neu (Kernel-Parameter
   wirken beim Boot).
3. Detailblick: `lspci -nnk -d 10de:25a2` — erwartet `Kernel driver in use: vfio-pci`.
4. Notbremse: `sudo nixos-rebuild switch --rollback` bzw. alte Generation im Bootmenü.

Hintergründe zum Passthrough-Design (D3cold, Blacklist, IOMMU): Kopf von `modules/vfio.nix`;
bekannte Stolperer: `troubleshooting.md`.

## Geltungsbereich

Der Check kennt keine konkrete Hardware: Er prüft, **was auch immer** in `host.passthroughIds`
deklariert ist. Seit der Kurskorrektur vom **2026-07-16** (AI-VM verworfen, dGPU zurück an den
Host — s. `troubleshooting.md` E) deklariert **kein Host** mehr Passthrough-Geräte — der Check
schweigt daher überall („nicht zuständig", Exit 0) und wird erst mit einem künftigen
Passthrough-Gerät wieder aktiv. Das Skript bleibt wie `modules/vfio.nix` als generische
Infrastruktur im Repo und im Installer.

## Bekannte Einschränkung: False Positive bei D3cold

Liegt eine gebundene Karte in **D3cold** (Slot stromlos), verschwinden Teilfunktionen komplett
vom PCI-Bus — beobachtet bei der HDMI-Audio-Funktion `10de:2291` der RTX 2050. Der Check meldet
dann fälschlich „deklariertes Geraet nicht auf dem PCI-Bus gefunden" (Exit 1), obwohl gerade
alles richtig läuft: Das Verschwinden ist der **Beweis** des erfolgreichen Stromsparens, nicht
ein gerissener Passthrough. Dreifach reproduziert (2026-07-16).

**Merkposten:** Check D3cold-aware machen — z. B. Warnung unterdrücken, wenn eine andere
Funktion desselben Slots korrekt an `vfio-pci` gebunden ist und der Slot schläft. Am Referenzgerät
durch den dGPU-Rückbau obsolet, generisch für künftige Passthrough-Hosts weiterhin sinnvoll;
geplant nach dem A4-Test.

> Stand: 2026-07-23. Bei Abweichungen gilt das Skript selbst (Kopf-Kommentar).
