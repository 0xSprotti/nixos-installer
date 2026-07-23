# update-all.sh — Ein-Klick-Update

**Zweck:** Ein Befehl hebt alles auf den neuen Stand — nixpkgs (Flake), Host-System, VMs,
Firmware/BIOS — mit Paket-Diff **vor** der Aktivierung, Smoke-Checks danach, einem Session-Log je
Lauf und einer Update-Chronik in git.

## Aufruf

```bash
bash update-all.sh               # kompletter Lauf (interaktiv)
bash update-all.sh --host-only   # nur Flake + Host (inkl. Smoke-Checks); keine VMs, keine Firmware
bash update-all.sh --dry-run     # zeigt nur, was passieren würde — einziger Modus ohne TTY
bash update-all.sh --help        # Kopf-Doku anzeigen
```

Jeder Lauf außer `--dry-run` braucht ein interaktives Terminal — die **eingreifenden** Schritte
(Host-Aktivierung, Rabby-Bump, Firmware) haben ihr `[j/n]`-Gate. Die VM-Deploys (Abschnitt 3)
laufen seit 2026-07-21 bewusst **gate-frei**: der Stand-Marker macht die Entscheidung trivial
(„Image nachweislich veraltet + VM aus" → deployen), und die Update-Chronik garantiert den
Rückweg auf jeden früheren Stand. Ein `--yes` gibt es bewusst nicht (2026-07-12 entfernt): am
sudo-Prompt löste es „unbeaufsichtigt" nie ein, und am Firmware-Gate wäre ein automatisches Ja
gleichbedeutend mit einem unangekündigten Reboot.

## Ablauf im Detail

### 0b) Payload-Abgleich (vor allem anderen)

Existiert `payload-sources.conf` in der Repo-Wurzel, gleicht der Lauf zuerst die dort
gelisteten Quellen ab (`name=url-oder-pfad[#ref]`, eine je Zeile; jede Quelle muss ein
Git-Repo sein — Format, Pinning und interne Spiegel: `docs/README-payload.md`). Je Quelle:
Clone/Pull in den Cache (`~/.cache/nixos-config-payloads/<name>`), `files/` gegen das Repo
diffen, Diff anzeigen, `[J/n]`-Gate (Enter = übernehmen), atomare Übernahme und ein
Provenienz-Commit **nur über diese Dateien** (`payload: <name> → <rev>`, Dateiliste im
Body — Chronik: `git log --oneline --grep=payload`). Ohne die Datei schläft der Abschnitt
still. Schutzmechanik: **uncommittete** Änderungen an payload-verwalteten Dateien blockieren
genau diese Quelle („erst committen"); Offline/Fehler bedeuten Warnung + Weiterlauf; der
Payload **löscht nie**. Bringt eine Übernahme ein neues `update-all.sh` mit, wird es atomar
ersetzt (tmp+mv — die laufende Instanz liest ungestört weiter) und ein Neustart des Laufs
mit der frischen Version angeboten. `--dry-run` zeigt den Diff, übernimmt aber nichts;
`--host-only` ändert an 0b nichts (Payload betrifft auch den Host).


**1) `nix flake update`** — bumpt `flake.lock` (nixpkgs & Co.). Ab hier wacht ein Trap: stirbt das
Skript vor erfolgreichem Abschluss (Strg-C, Fenster zu, Fehler), wird der Bump verworfen — Repo
und laufendes System bleiben deckungsgleich.

**2) Host bauen → Diff → Gate → aktivieren** — erst `nixos-rebuild build` (ohne sudo, ohne
Aktivierung), dann der Paket-Diff „aktiv → neu": `nvd`, wenn vorhanden (kommt über
`modules/host-updates.nix`), sonst `nix store diff-closures`. Erst nach `[J/n]`-Bestätigung folgt
`sudo nixos-rebuild switch`. Bei „n" oder Fehler: Bump verwerfen, nichts aktivieren. Ist die
Closure unverändert (nur Input-Bump im Lock), entfällt das Gate.

**2b) Smoke-Checks** — direkt nach der Aktivierung, bewusst **vor** den VM-Gates: erst
`systemctl is-system-running --wait` (max. 90 s — lässt die Aktivierungs-Jobs leerlaufen, sonst
misst man startende Services), bei allem außer `running` die fehlgeschlagenen Units; danach alle
`check-*.sh` im Repo-Root (Discovery per Namensmuster, jeder Check selbst-guardend). Semantik:
**warnen, nie abbrechen** — der Host ist bereits aktiv; bei Warnungen kommt am Skriptende ein
gebündelter Hinweis samt Rollback-Befehl. Zusätzlich vergleicht 2b den **gebooteten mit dem
konfigurierten Kernel** (`/run/booted-system/kernel` vs. `/run/current-system/kernel`): NixOS
aktiviert einen neuen Kernel erst beim Reboot — weichen die Pfade ab, warnt das Skript sofort
und erinnert am Skriptende gebündelt an den zeitnahen Neustart (BSI SYS.2.3.A4). Bewusst kein
Zwangs-Reboot; bis zum Neustart läuft der Host auf dem alten Kernel-Stand weiter.

**2c) Rabby-Pin (browser-vm)** — die Wallet-Extension ist bewusst gepinnt (Version + Hash in
`hosts/browser-vm/configuration.nix`; „ein Wallet-Update ist eine bewusste Commit-Entscheidung,
kein stiller Store-Push"). Dieser Schritt automatisiert nur die **Mechanik**, nicht die
Entscheidung: er vergleicht den Pin mit der neuesten GitHub-Release, zeigt den
**Release-Notes-Link** und fragt mit **Default NEIN**. Erst nach `j` ermittelt
`nix store prefetch-file` den neuen Hash (lädt nur das Zip, kein Image-Build), Version + Hash
werden per sed ersetzt (mit Eindeutigkeits-Guards) und als **eigener Commit** festgeschrieben
(`browser-vm: rabby X → Y`, Release-Link im Body). Das frische Image baut anschließend
Abschnitt 3 von selbst — die Config-Änderung lässt den Stand-Marker abweichen. Selbst-guardend:
offline / API-Fehler / kein curl → Hinweis, Lauf geht normal weiter. `--host-only` überspringt.

**3) VM-Images Stand-gesteuert nachziehen** — alle vorhandenen `deploy-*-vm.sh` werden entdeckt;
statt blinder Nachfrage entscheidet der **Stand-Marker** neben dem Image
(`/var/lib/libvirt/images/<vm>.flake-rev`, geschrieben vom Deploy; Formel: Hash über
`flake.lock` + Gast-Config, gespiegelt in den Deploy-Skripten):

- **Marker identisch** → Image nachweislich aktuell, wird still mit ok übersprungen.
- **Marker abweichend/fehlend + VM aus** → Deploy läuft **ohne Gate** mit `--no-start`: die VM
  war aus und bleibt aus (on-demand-Prinzip); der nächste Icon-Start bootet — und verifiziert
  damit — das frische Image.
- **Marker abweichend + VM läuft** → die VM wird **nie angefasst** (keine abgerissene
  Zed-Session, kein unterbrochenes Keystone-Signing); stattdessen Sammel-Hinweis am Skriptende,
  und der Marker erinnert bei **jedem** Folgelauf, bis wirklich deployt wurde.

Bewusste Grenze: der Marker erfasst `flake.lock` + die jeweilige Gast-Config — Änderungen an
`flake.nix` selbst oder geteilten Modulen sieht er nicht (die VM-Configs importieren keine
Repo-Module; solche Fälle deployt man ohnehin von Hand, was den Marker mitschreibt).

**4) Commit** — `flake.lock` wird als du (nicht root) committet; **der Paket-Diff steht im
Commit-Body**, der Hostname im Betreff (der Diff ist host-spezifisch). `git log -- flake.lock`
ist damit die Update-Chronik — nach `git push` auch offsite lesbar. Fehlgeschlagene Läufe
committen nie (der Bump wird ja verworfen); dafür ist das Session-Log da.

**5) Firmware/BIOS (fwupd/LVFS)** — bewusst der **letzte** Schritt: `refresh` → `get-updates` →
`[j/N]`-Gate → `fwupdmgr update`.

> ⚠️ Ein bestätigtes Firmware-Update **rebootet sofort**. Deshalb liegt dieser Schritt hinter dem
> Commit — ab da ist nichts mehr offen. `--host-only` überspringt den Firmware-Teil komplett.

## Session-Log

Jeder Lauf (außer `--dry-run`) wird komplett mitgeschnitten:
`~/.local/state/update-all/<Datum>_<Host>.log` — Diff, alle Gate-Antworten, VM-Deploys, Firmware
und vor allem **Fehler und Abbrüche**. Die letzten 20 Läufe bleiben liegen; lesen mit `less -R`
(ANSI-Farben bleiben drin). Am Log-Anfang steht der **Vorzustand** (`systemctl --failed` vor dem
Update) — trennt „neu kaputt" von „war schon kaputt". `/home` liegt außerhalb der
NixOS-Generationen: ein Rollback lässt die Logs unangetastet.

## Zusammenspiel mit der Update-Erinnerung

`modules/host-updates.nix` liefert das Desktop-Icon „NixOS aktualisieren" und einen stündlichen
Check, der den **laufenden** Stand (`nixos-version`) mit dem Upstream vergleicht und per
Notification erinnert. „Später"-Klicks (1 h / 8 h / bis morgen) setzen einen transienten
systemd-Timer (`systemd-run --user --on-calendar`) — Wanduhrzeit, übersteht also auch Suspend;
sichtbar mit `systemctl --user list-timers` (Unit `nixos-update-snooze`). Außerdem bringt das
Modul `nvd` (lesbarer Diff) und `services.fwupd` (Firmware-Teil) mit.

## Wenn etwas schiefgeht

- **Build/Switch scheitert oder Gate = „n":** Bump wird verworfen; System und Repo unverändert.
- **Smoke-Check warnt:** Details stehen im Terminal und im Session-Log; Rollback bei Bedarf mit
  `sudo nixos-rebuild switch --rollback` (oder alte Generation im Bootmenü wählen).
- **„Reboot ausstehend" (Kernel):** kein Fehler — das Update hat einen neuen Kernel gestaged, der
  erst beim Neustart übernimmt. Zeitnah rebooten (SYS.2.3.A4); prüfen jederzeit mit
  `readlink -f /run/booted-system/kernel /run/current-system/kernel` (identisch = erledigt).
- **„VM-Images noch auf altem Stand" am Skriptende:** kein Fehler — die VM lief während des
  Updates (oder ihr Deploy scheiterte) und wurde bewusst nicht angefasst. Nachholen mit dem
  angezeigten `bash deploy-*-vm.sh`; alternativ erinnert jeder weitere Lauf von selbst.
- **Rabby-Bump übersprungen („Hash nicht ermittelbar" / „Pin-Muster nicht eindeutig"):** der
  manuelle Weg aus dem Config-Kopf gilt unverändert — `rabbyVersion` bumpen,
  `hash = lib.fakeHash`, deployen (der Build nennt den echten Hash), committen. Details:
  `troubleshooting.md`, Abschnitt D.
- **„Was hat das letzte Update geändert?"** — Session-Log, `git log -- flake.lock`, oder
  Retro-Diff zwischen Generationen (solange keine GC lief):

  ```bash
  nixos-rebuild list-generations
  nvd diff /nix/var/nix/profiles/system-47-link /nix/var/nix/profiles/system-48-link
  ```

- Mehr Fälle: `troubleshooting.md`, Abschnitt D.

## Exit-Verhalten

- `0` — regulärer Abschluss (auch bei „n" an einem Gate und bei Smoke-**Warnungen**)
- `1` — harter Fehler (`die`), z. B. Build oder Switch fehlgeschlagen
- `2` — unbekanntes Argument
- `130 / 143 / 129` — INT / TERM / HUP (der Trap räumt den flake.lock-Bump weg)

> Stand: 2026-07-23. Bei Abweichungen gilt das Skript selbst (Kopf-Kommentar).
