# Payload-System — wie dieses Repo aktuell bleibt

> Dein `~/nixos-config` ist **dein** Repo — aber ein Großteil seiner Dateien wird zentral
> gepflegt und dir als **Payload** ausgeliefert: aus dem öffentlichen **Basis-Repo**
> (Installer + Arbeitsplatz-Härtung) und optional aus dem privaten **Extensions-Repo**
> (z. B. die VM-Suite). `update-all.sh` gleicht beide Quellen bei jedem Lauf ab und
> übernimmt Neues erst nach deinem ausdrücklichen `[J/n]`. Dieses Dokument erklärt die
> zwei Zonen deines Repos, den Update-Fluss und wie du Quellen pinnst oder intern spiegelst.

---

## 1. Die zwei Zonen deines Repos

| Zone | Pfade | Regel |
|---|---|---|
| **Payload-Zone** | `modules/`, `docs/`, `flake.nix`, `update-all.sh`, `usbguard-sync.sh`, `check-*.sh`, `deploy-*-vm.sh`, `hosts/dev-vm/` + `hosts/browser-vm/` (nur die `configuration.nix`) | Zentral gepflegt. **Nicht editieren** — Updates kommen über das Gate (s. u.). Bewusste Abweichung: erst committen, dann abweichen (Abschnitt 5). |
| **Host-Zone** | `hosts/<dein-hostname>/` — `configuration.nix`, `disk.nix`, `hardware-configuration.nix`, `usbguard-rules.conf`; dazu personen-eigene Dateien wie `hosts/dev-vm/ssh.pub`, `hosts/browser-vm/ssh-debug.pub` und die generierten VM-XMLs | **Deine** Dateien. Der Payload fasst sie nie an. Hier lebt alles Host- und Personen-Spezifische. |

Kurzform: **Config nach `hosts/<host>/`, alles andere kommt per Payload.**

---

## 2. Woher die Dateien kommen

Beide Auslieferungs-Repos sind reine **Daten-Container**: ein `files/`-Verzeichnis, das die
Zielstruktur 1:1 spiegelt, plus README und Lizenz — **keine Skripte** (die gesamte
Übernahme-Logik lebt in deinem `update-all.sh` und aktualisiert sich darüber selbst).

- **Basis** (öffentlich): Installer, geteilte Module (`desktop`, `hardening`, `vfio`,
  `host-updates`), `update-all.sh`, USBGuard-Werkzeuge, generische Doku, `flake.nix`
  (Auto-Discovery — neue Hosts und VM-Gäste werden ohne Flake-Änderung erkannt).
- **Extensions** (privat, kostenpflichtig — Zugang als Repo-Collaborator): abgeschlossene
  Wert-Pakete, z. B. die **VM-Suite** (Zero-Trust-browser-VM, dev-VM, VM-Netz-Isolierung,
  Deploys, Checks, Doku). Weitere Module (etwa AD-Integration) erscheinen als eigene Quelle
  nach demselben Muster.

---

## 3. Quellen-Datei: `payload-sources.conf`

Liegt in der Repo-Wurzel; `install.sh` legt sie mit der Basis-Zeile an. Format —
**eine Quelle je Zeile**, `#` kommentiert:

```
# name=url-oder-pfad[#ref]     ref = Branch, Tag oder Commit (Pin)
basis=https://github.com/<anbieter>/nixos-installer.git#v1
# extensions=git@github.com:<anbieter>/nixos-extensions.git#v1   # nach Kauf eintragen
```

Drei Betriebsmodelle, jeweils **eine Zeilen-Änderung**:

1. **Folgen** — Branch als `ref` (oder keins): jeder `update-all`-Lauf bietet den
   neuesten Stand an.
2. **Pinnen** — Tag/Commit als `ref`: ihr bleibt auf einem geprüften Stand
   (z. B. `#v1.2`), bis ihr den Pin bewusst hebt. Empfohlen für Firmen.
3. **Intern spiegeln** — beide Repos auf den eigenen Git-Server spiegeln
   (`git clone --mirror` + Cron/CI für `git remote update`) und die URLs hier
   austauschen. Auch lokale Pfade sind gültig (`extensions=/srv/git/nixos-extensions.git`).

**Regel:** Jede Quelle muss ein **Git-Repo** sein (auch der Spiegel) — die Versions-Identität
einer Übernahme ist der Git-Stand der Quelle, er landet in der Commit-Message (s. u.).
Basis und Extensions zusammen aktualisieren (gleicher Release-Stand), nicht mischen.

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

## 6. Extensions aktivieren (Beispiel VM-Suite)

1. Zugang erhalten (Collaborator auf dem Extensions-Repo), dann die `extensions=`-Zeile in
   `payload-sources.conf` eintragen (Abschnitt 3).
2. `bash update-all.sh` — das Gate zeigt einmalig alle Suite-Dateien als Diff, `J` übernimmt.
3. Aktivieren (bewusste Host-Entscheidung, drei Zeilen in `hosts/<host>/configuration.nix`):
   das Import der VM-Module plus `networking.nftables.enable = true;` und
   `hardening.vmNetIsolation.enable = true;` — im Detail in den mitgelieferten
   `README-deploy-*.md` beschrieben.
4. Deployen: `bash deploy-dev-vm.sh` (seedet beim ersten Lauf automatisch deinen SSH-Key
   nach `hosts/dev-vm/ssh.pub`) bzw. `bash deploy-browser-vm.sh` (SSH dort bewusst **aus**,
   solange du nicht selbst `hosts/browser-vm/ssh-debug.pub` anlegst — Zero-Trust-Default).
   Die Flake entdeckt die neuen VM-Gäste automatisch; Suite-Updates laufen ab jetzt über
   denselben 0b-Fluss wie die Basis.

---

> Stand: 2026-07-23. Produzenten-Seite (Befüllung der Auslieferungs-Repos aus dem
> Referenz-Repo, Personalisierungs-Gate): `sync-payloads.sh` im Referenz-Repo.
