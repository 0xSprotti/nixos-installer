# Payload-System — wie dieses Repo aktuell bleibt

> Dein `~/nixos-config` ist **dein** Repo — aber ein Großteil seiner Dateien wird zentral
> gepflegt und dir als **Payload** ausgeliefert: aus dem **Basis-Repo** (Installer +
> Arbeitsplatz-Härtung) und optional aus einem **Produkt-Repo** (z. B. der VM-Suite).
> `update-all.sh` gleicht alle Quellen bei jedem Lauf ab und übernimmt Neues erst nach
> deinem ausdrücklichen `[J/n]`. Dieses Dokument erklärt die zwei Zonen deines Repos,
> den Update-Fluss und wie du Quellen pinnst oder intern spiegelst.

---

## 1. Die zwei Zonen deines Repos

| Zone | Pfade | Regel |
|---|---|---|
| **Payload-Zone** | `modules/`, `docs/`, `flake.nix`, `update-all.sh`, `usbguard-sync.sh`, `check-*.sh`, `deploy-*-vm.sh`, `hosts/dev-vm/` + `hosts/browser-vm/` (nur die `configuration.nix`) | Zentral gepflegt. **Nicht editieren** — Updates kommen über das Gate (s. u.). Bewusste Abweichung: erst committen, dann abweichen (Abschnitt 5). |
| **Host-Zone** | `hosts/<dein-hostname>/` — `configuration.nix`, `disk.nix`, `hardware-configuration.nix`, `usbguard-rules.conf`; dazu personen-eigene Dateien wie `hosts/dev-vm/ssh.pub`, `hosts/browser-vm/ssh-debug.pub` und die generierten VM-XMLs | **Deine** Dateien. Der Payload fasst sie nie an. Hier lebt alles Host- und Personen-Spezifische. |

Kurzform: **Config nach `hosts/<host>/`, alles andere kommt per Payload.**

---

## 2. Woher die Dateien kommen

Alle Auslieferungs-Repos sind reine **Daten-Container**: ein `files/`-Verzeichnis, das die
Zielstruktur 1:1 spiegelt, plus README und Lizenz — **keine Skripte** (die gesamte
Übernahme-Logik lebt in deinem `update-all.sh` und aktualisiert sich darüber selbst).

- **Basis** (öffentlich, `nixos-installer`): Installer, geteilte Module (`desktop`,
  `hardening`, `vfio`, `host-updates`), `update-all.sh`, USBGuard-Werkzeuge, generische
  Doku, `flake.nix` (Auto-Discovery — neue Hosts und VM-Gäste werden ohne Flake-Änderung
  erkannt).
- **Produkte**: abgeschlossene Wert-Pakete, je Produkt ein eigenes Repo. Aktuell die
  **VM-Suite** (`nixos-extensions-vm`: Zero-Trust-browser-VM, dev-VM, VM-Netz-Isolierung,
  Deploys, Checks, Doku). Weitere Produkte erscheinen nach demselben Muster.

Jedes Repo führt je NixOS-Release einen Branch `release-XX.YY` und darauf Tags
`vXX.YY.N`. `main` zeigt stets auf den aktuellen Release. Ein Versionssprung ist
also ein neuer Branch im selben Repo, kein neues Repo.

---

## 3. Quellen-Datei: `payload-sources.conf`

Liegt in der **Repo-Wurzel** deines `~/nixos-config`. `install.sh` legt sie bei der
Installation an (eigene Frage, Default „ja") und trägt die Basis-Zeile passend zum
installierten NixOS-Release ein — hast du den Installer von einem internen Spiegel
geklont, steht dessen URL drin. Ein späterer Installer-Lauf **überschreibt sie nie**.

Fehlt die Datei, schläft der Payload-Abgleich still; du legst sie dann von Hand an.
Format — eine Quelle je Zeile, `#` kommentiert:

```
# name=url-oder-pfad[#ref]     ref = Branch, Tag oder Commit (Pin)
basis=https://github.com/<anbieter>/nixos-installer.git#release-26.05
vm=https://github.com/<anbieter>/nixos-extensions-vm.git#release-26.05
# (weitere Produkte nach demselben Muster, z. B. ad=…)
```

Vier Betriebsmodelle, jeweils **eine Zeilen-Änderung**:

1. **Release-Linie folgen** — Branch als `ref` (`#release-26.05`): jeder
   `update-all`-Lauf bietet den neuesten Stand **dieser** Linie an, ohne
   Versionssprünge. Der empfohlene Normalfall, den auch `install.sh` einträgt.
2. **Pinnen** — Tag als `ref` (`#v26.05.3`): ihr bleibt exakt auf einem geprüften Stand,
   bis ihr den Pin bewusst hebt. Empfohlen für Firmen mit Change-Control.
   Veröffentlichte Tags werden **nie** verschoben — ein Fix ist immer `N+1`.
3. **Immer aktuell** — **kein** `ref`: die Quelle folgt `main` und damit dem jeweils
   aktuellen Release. Nur sinnvoll, wenn ihr euer System beim NixOS-Sprung ohnehin
   mitzieht — sonst treffen neue Module auf eine ältere NixOS-Version.
4. **Intern spiegeln** — die Repos auf den eigenen Git-Server spiegeln
   (`git clone --mirror` + Cron/CI für `git remote update`) und die URLs hier
   austauschen. Auch lokale Pfade sind gültig (`vm=/srv/git/nixos-extensions-vm.git`).

**Regel:** Jede Quelle muss ein **Git-Repo** sein (auch der Spiegel) — die Versions-Identität
einer Übernahme ist der Git-Stand der Quelle, er landet in der Commit-Message (s. u.).
Basis und Produkte auf **denselben Release-Stand** setzen, nicht mischen.

---

## 4. Der Update-Fluss (`update-all.sh`, Abschnitt 0b)

Ganz am Anfang jedes Laufs, **vor** dem flake-Update, je Quelle:

1. **Holen:** Clone/Pull in einen lokalen Cache. Offline oder Quelle nicht erreichbar →
   Hinweis, der Lauf geht normal weiter (kein harter Fehler).
2. **Vergleichen:** `files/` der Quelle gegen dein Repo. Identisch → stille Ok-Zeile, fertig.
3. **Gate:** Bei Abweichung siehst du den vollständigen Diff und entscheidest `[J/n]`.
   `n` = nichts passiert; der nächste Lauf fragt erneut.
4. **Übernehmen + Provenienz-Commit:** Nach `J` werden die Dateien kopiert und **nur diese
   Dateien** automatisch committet — Message `payload: <quelle> → <rev>` mit Dateiliste im
   Body. Deine übrigen uncommitteten Arbeiten bleiben unberührt.
   Chronik-Abfrage: `git log --oneline --grep=payload`.
5. **Selbst-Update:** Bringt der Payload ein neues `update-all.sh` mit, wird es atomar
   ersetzt und der Lauf bietet einen Neustart mit der frischen Version an.

**Schutzgitter:** Liegen **uncommittete** Änderungen an payload-verwalteten Dateien vor,
verweigert 0b die Übernahme dieser Quelle mit klarer Ansage („erst committen") — die
einzige Stelle, an der sonst Arbeit stumm verloren gehen könnte. Und: der Payload
**löscht nie** Dateien; Entfernungen sind Release-Note plus bewusster Handgriff.

---

## 5. Bewusst vom Payload abweichen

Du darfst — aber sichtbar: Änderung an einer Payload-Datei **committen** (das Gitter aus
Abschnitt 4 besteht darauf). Beim nächsten Payload-Update zeigt der Gate-Diff exakt die
Rücknahme deiner Änderung — `n` behält die Abweichung, `J` folgt Upstream, und dein Stand
bleibt per `git revert` / `git cherry-pick` jederzeit rekonstruierbar. Die konkreten
Kommandos samt Erklärung: `git-cheatsheet.md`, Abschnitt 12.

---

## 6. Ein Produkt aktivieren (Beispiel VM-Suite)

1. Quellen-Zeile in `payload-sources.conf` eintragen (Abschnitt 3) — die öffentliche
   HTTPS-URL genügt, es ist kein Zugang nötig. `install.sh` hat die Zeile bereits
   auskommentiert vorbereitet.
2. `bash update-all.sh` — das Gate zeigt einmalig alle Suite-Dateien als Diff, `J` übernimmt.
3. Aktivieren (bewusste Host-Entscheidung): `install.sh` hat in
   `hosts/<host>/configuration.nix` einen auskommentierten Block hinterlegt — die zwei
   Modul-Pfade in der `imports`-Liste einkommentieren, dazu `networking.nftables.enable`
   und `hardening.vmNetIsolation.enable`, und den Benutzer um die Gruppe `libvirtd`
   ergänzen. Details in den mitgelieferten `README-deploy-*.md`.
4. Deployen: `bash deploy-dev-vm.sh` (seedet beim ersten Lauf automatisch deinen SSH-Key
   nach `hosts/dev-vm/ssh.pub`) bzw. `bash deploy-browser-vm.sh` (SSH dort bewusst **aus**,
   solange du nicht selbst `hosts/browser-vm/ssh-debug.pub` anlegst — Zero-Trust-Default).
   Die Flake entdeckt die neuen VM-Gäste automatisch; Suite-Updates laufen ab jetzt über
   denselben 0b-Fluss wie die Basis.

---

> Stand: 2026-07-27.
