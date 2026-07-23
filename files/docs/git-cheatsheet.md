# Git-Cheat-Sheet — Alltag in der dev-VM

> Schnellreferenz für den Alltag in der dev-VM (Zed-Terminal **oder** Git-Panel).
> **Beispiel-Setup** dieses Sheets: ein Projekt-Repo mit `main` (geschützt, Production) und
> `staging` (Dauer-Arbeitsbranch, Test-Deploys); Push/Pull laufen per
> **SSH-Agent-Forwarding** (kein Schlüssel in der VM). Heißen deine Branches anders,
> gelten alle Rezepte sinngemäß.
>
> **Wichtig (neu):** `main` ist **geschützt** — kein Direkt-Push. Du arbeitest auf
> `staging`; nach Production kommst du nur über einen **PR `staging → main`**, den du
> selbst mergst. Push auf `staging` → deployt in deine **Test-Umgebung** (z. B. isolierter
> DB-Branch + Preview); Merge `staging → main` → deployt auf **Production**.

---

## 0. Einmal pro Sitzung (sonst scheitert Push/Pull)

Auf dem **Host**, bevor du übers Icon in die VM gehst:
```
ssh-add            # Key in den Agent (Passphrase 1x) -> Forwarding hat etwas weiterzureichen
```
Gegencheck in der VM: `ssh-add -l` muss den Host-Key zeigen. Fehlt er → Push/Pull fragen nach
Zugangsdaten oder hängen.

---

## 1. Der tägliche Loop (auf `staging`)

```
git switch staging         # sicher auf dem Arbeitsbranch landen
git pull                   # neuesten Stand holen (bevor du loslegst)
git status                 # was hat sich geaendert? (immer der erste Blick)
git add -A                 # alle Aenderungen fuer den Commit vormerken (stagen)
git commit -m "Nachricht"  # Commit lokal anlegen
git push                   # Commits nach staging hochladen -> deployt in die Test-Umgebung
```
Merksatz: **switch → pull → ändern → status → add → commit → push.** `push` geht nach `staging`, **nicht** nach
Production. Jeder Push auf `staging` fährt deine Test-Umgebung hoch (DB-Migrations,
Preview-Build — je nach Projekt) — hier wird getestet.

Vorher immer sicherstellen, dass du **auf `staging`** stehst:
```
git branch --show-current  # muss "staging" zeigen
```

---

## 2. Nach Production bringen (`staging → main`)

`main` ist geschützt — **direkt pushen geht nicht** (`git push origin main` wird abgelehnt).
Der Weg nach Production ist immer ein **Pull Request**, den **du bewusst mergst**. Zwei Wege:

**Weg A — GitHub-Web (klicken):**
1. GitHub → **Pull requests** → **New pull request** → base: `main`, compare: `staging` → **Create pull request**
2. Prüfen: Diff, Preview-Deploy, Status-Checks im PR
3. **Merge pull request** klicken — *das ist deine Freigabe* → Deploy auf Production
4. **NICHT** „Delete branch" klicken! `staging` bleibt dein Dauer-Arbeitsbranch.

**Weg B — `gh` CLI (Terminal):** (einmalig `gh auth login`)
```
gh pr create --base main --head staging --fill   # PR aus den Commits erstellen
gh pr view --web                                  # im Browser ansehen (Diff, Preview)
gh pr checks                                       # Status-Checks / CI ansehen
gh pr merge --merge                                # mergen -> Deploy auf Production
```
**Wichtig:** **kein** `--delete-branch` verwenden — `staging` muss erhalten bleiben
(daran hängt deine persistente Test-Umgebung).

Merksatz: **`staging` = testen · Merge nach `main` = live.** Der Merge ist die einzige Tür
nach Production, und nur du öffnest sie (auch der KI-Agent kommt an `main` nicht vorbei).

---

## 3. Ansehen / Status

```
git status                 # geaenderte/gestagte Dateien
git status -s              # Kurzform (1 Zeile pro Datei)
git diff                   # was ist geaendert, aber NICHT gestagt?
git diff --staged          # was ist gestagt (kommt in den naechsten Commit)?
git log --oneline -10      # letzte 10 Commits, knapp
git log --oneline --graph --all   # Verlauf mit Branch-Struktur
git branch                 # lokale Branches (* = aktueller)
git branch -r              # Remote-Branches (origin/...)
```

---

## 4. Stagen & Committen

```
git add <datei>            # nur eine Datei stagen
git add -A                 # alles (neu / geaendert / geloescht)
git add -p                 # interaktiv: nur einzelne Haeppchen einer Datei stagen
git restore --staged <datei>   # Datei wieder aus dem Stage nehmen (Aenderung bleibt erhalten)
git commit -m "..."        # committen
git commit --amend         # letzten Commit korrigieren (Nachricht/Inhalt) -- NUR solange nicht gepusht!
```

---

## 5. Branches (du hast `main` + `staging`)

```
git switch staging         # auf Branch staging wechseln (modern; = git checkout staging)
git switch -c neuer-branch # neuen Branch anlegen UND hinwechseln
git branch                 # wo bin ich? (* markiert den aktuellen)
git merge staging          # staging IN den aktuellen Branch mergen (erst auf den Ziel-Branch wechseln!)
git branch -d alt          # bereits gemergten Branch loeschen
```
Vor dem Wechsel **committen oder stashen** (s. u.) — sonst nimmt git offene Änderungen mit hinüber.

**`main` nicht lokal mergen und pushen** — das ginge nicht durch (geschützt). Nach `main`
kommst du ausschließlich über den PR aus Abschnitt 2.

---

## 6. Remote synchronisieren

```
git fetch                  # Remote-Stand HOLEN (nur Info), aendert deinen Code NICHT
git pull                   # fetch + MERGE in deinen Branch (wenn woanders am Branch gearbeitet wurde)
git push                   # lokale Commits hochladen (auf staging)
git push -u origin <branch># beim ERSTEN Push eines neuen Branches (setzt den Upstream)
```
Faustregel: vor dem Arbeiten `git pull`, am Ende `git push`.

---

## 7. Rückgängig machen (vom harmlosesten zum schärfsten)

```
git restore <datei>        # ungestagte Aenderung VERWERFEN (zurueck auf letzten Commit)
git restore --staged <datei>   # nur unstagen (Aenderung bleibt erhalten)
git stash                  # ALLE offenen Aenderungen wegpacken -> Arbeitsbaum sauber
git stash pop              # weggepackte Aenderungen zurueckholen
git revert <commit>        # Commit rueckgaengig per NEUEM Commit (sicher, auch nach Push)
git reset --soft HEAD~1    # letzten Commit aufloesen, Aenderungen bleiben gestagt
git reset --hard HEAD      # ACHTUNG: verwirft ALLE offenen Aenderungen UNWIDERRUFLICH
```
Regel: Nach einem `push` die Historie **nicht** mehr umschreiben (`reset`/`amend`) → nimm `revert`.

---

## 8. Klonen

```
git clone -b <branch> <ssh-url>                 # checkt <branch> aus, laedt aber alle in die Historie
git clone --single-branch -b <branch> <ssh-url> # holt NUR diesen Branch
```
Immer die **SSH-URL** (`git@github.com:...`), nie HTTPS → sonst Token nötig.

---

## 9. Merge-Konflikt (wenn pull/merge kollidiert)

1. `git status` zeigt die betroffenen Dateien.
2. In **Zed** die Konfliktmarken (`<<<<<<<` / `=======` / `>>>>>>>`) auflösen — Zed markiert sie und
   bietet „Accept Current / Incoming / Both" an.
3. `git add <datei>` (Konflikt als gelöst markieren).
4. `git commit` (schließt den Merge ab).

Neu ansetzen / abbrechen: `git merge --abort`

---

## 10. Zed-Panel ↔ Terminal (dasselbe, zwei Wege)

| im Git-Panel (`Strg+Shift+G`)        | im Terminal              |
|--------------------------------------|--------------------------|
| Datei anklicken → Diff               | `git diff`               |
| „+" / Haken an der Datei             | `git add <datei>`        |
| „Stage All"                          | `git add -A`             |
| Nachricht tippen + Commit-Knopf      | `git commit -m "..."`    |
| Push / Pull / Fetch im Menü          | `git push` / `pull` / `fetch` |

Branch-Name steht unten in Zeds Statusleiste; Klick darauf → Branch wechseln.

---

## 11. „Hilfe, …" — die häufigen Fälle

- **… mein Push auf `main` wird abgelehnt** („protected branch" / „Changes must be made through a
  pull request"): **Das ist Absicht.** `main` ist geschützt. Geh über einen PR von `staging`
  (s. Abschnitt 2). Direkt auf `main` pushen ist bewusst gesperrt.
- **… ich hab am falschen Branch committet** (noch nicht gepusht):
  ```
  git reset --soft HEAD~1                  # Commit aufloesen, Aenderungen bleiben gestagt
  git stash && git switch <richtig> && git stash pop && git commit -m "..."
  ```
- **… nach dem Merge fragt GitHub „Delete branch?"**: **Nein — `staging` niemals löschen.**
  `staging` ist dein Dauer-Arbeitsbranch, an dem deine persistente Test-Umgebung hängt.
  Button einfach ignorieren (bzw. bei `gh` kein `--delete-branch`).
- **… ich will alle lokalen Änderungen wegwerfen:**
  ```
  git restore .            # ungestagte; oder (auch gestagte): git reset --hard HEAD
  ```
- **… push wird abgelehnt („non-fast-forward"):** der Branch wurde woanders bewegt →
  ```
  git pull                 # holt + merged; Konflikte ggf. loesen; dann erneut: git push
  ```
- **… ich hab einen Branch auf GitHub umbenannt** (`alt` → `neu`), lokal nachziehen:
  ```
  git branch -m alt neu                  # lokalen Branch umbenennen
  git fetch origin --prune               # neuen Remote-Branch holen, alten origin/alt entfernen
  git branch -u origin/neu neu           # Tracking auf den neuen Namen setzen
  git remote set-head origin -a          # origin/HEAD aktualisieren (nur relevant, wenn der Default-Branch betroffen war)
  ```
  Vorher muss das Agent-Forwarding stehen (Host: `ssh-add`, s. Abschnitt 0) — sonst scheitern
  `fetch`/`set-head` mit `Permission denied (publickey)`. Gegencheck: `git branch -vv` zeigt
  `[origin/neu]`.
- **… push fragt nach Zugangsdaten / hängt:** Agent ist leer → auf dem **Host** `ssh-add`, dann erneut.
- **… was hab ich zuletzt gemacht?** `git log --oneline -5`
- **… wem gehört diese Zeile / wann kam sie?** `git blame <datei>`

---

## 12. Payload-Commits verwalten (Basis & Extensions)

Dein `~/nixos-config` mischt **eigene** Commits (Host-Config, flake.lock-Updates) mit
**Payload-Commits**: Übernahmen aus dem Basis- bzw. Extensions-Repo, die `update-all.sh`
nach deinem `[J/n]` am Gate automatisch committet — Message-Muster `payload: <quelle> → <rev>`.
Architektur und Update-Fluss: `docs/README-payload.md`.

```
git log --oneline --grep=payload           # Welche Payload-Stände habe ich wann übernommen?
git show <payload-commit> --stat           # Was genau kam mit dieser Übernahme?
git revert <payload-commit>                # Übernahme sauber zurücknehmen (neuer Commit,
                                           #   auch nach Push sicher — Historie bleibt intakt)
```

**Eigene Änderung an einer Payload-Datei** (bewusste Abweichung): erst **committen** — das
Dirty-Schutzgitter verweigert Übernahmen über uncommittete Payload-Dateien, damit nichts
stumm verloren geht. Beim nächsten Payload-Update zeigt der Gate-Diff dann exakt die
Rücknahme deines Tweaks: `n` behält die Abweichung (der nächste Lauf erinnert erneut), `J`
übernimmt Upstream — dein Tweak liegt sicher in der Historie:

```
git log --oneline -- <datei>               # meinen früheren Tweak-Commit finden
git cherry-pick <tweak-commit>             # ihn nach der Übernahme wieder aufsetzen
```

Merksatz: **Payload-Zone nie „mal eben" editieren** — entweder Upstream folgen oder
bewusst, committet und damit sichtbar abweichen.

---

## Mini-Glossar

- **stagen** (`add`) = „dieser Teil soll in den nächsten Commit". Der Stage ist die Vorauswahl.
- **commit** = ein lokaler Schnappschuss. Bleibt auf deinem Rechner, bis du `push`st.
- **fetch** = Remote-Info holen (Code unangetastet) · **pull** = holen **und** einbauen.
- **PR** (Pull Request) = Antrag, einen Branch in einen anderen zu übernehmen. Bei dir: der Weg
  von `staging` nach `main` — und damit die einzige Tür nach Production.
- **staging** = dein Dauer-Arbeitsbranch (dort arbeitet auch der KI-Agent); Push dahin → Test-Umgebung.
- **HEAD** = der Commit, auf dem du gerade stehst · `HEAD~1` = einer davor.
- **origin** = dein GitHub-Remote (die SSH-URL).
