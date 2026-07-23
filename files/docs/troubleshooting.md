# Troubleshooting / Runbook — Arbeitsplatz & VMs

> Gesammelte Fehlerbilder aus den Bau-Sessions samt Ursache & Fix — damit ein bekanntes Problem
> nicht erneut diagnostiziert werden muss. Suche per **Strg-F** nach der Fehlermeldung oder dem Symptom.
> Stand: 2026-07-22 · wächst mit jeder gelösten Stolperstelle.

Format je Eintrag: **Symptom** (was du siehst) · **Ursache** · **Fix**.
„✓ erlebt" = real aufgetreten und gelöst · „geparkt" = bekannt, bewusst nicht weiterverfolgt.

---

## A. Build / Flake / Nix

### „Refusing to evaluate package 'claude-code-…' because it has an unfree license" ✓ erlebt
- **Symptom:** `bash deploy-dev-vm.sh` bricht beim Image-Build ab; der **Host**-Rebuild lief vorher sauber durch.
- **Ursache:** `claude-code` ist unfrei. Die dev-VM-Config wird **eigenständig** evaluiert (eigener
  nixpkgs) und verweigert unfreie Pakete. Der Host war nicht betroffen, weil er kein `claude-code` hat.
  Es ist **kein** Neustart-/Re-exec-/„dirty tree"-Problem.
- **Fix:** in `hosts/dev-vm/configuration.nix`, danach `git add -A && bash deploy-dev-vm.sh` (Host NICHT neu bauen):
  ```nix
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "claude-code" ];
  ```

### „warning: Git tree '…' is dirty" + Änderung wirkt nicht ✓ erlebt
- **Symptom:** Eine gerade editierte Datei scheint beim Build ignoriert zu werden; dazu die dirty-Warnung.
- **Ursache:** Flakes bauen nur aus **Git-getrackten** Dateien. Eine **neue, ungetrackte** Datei sieht
  der Build gar nicht. Die dirty-Warnung selbst ist **harmlos und erwartet**.
- **Fix:** vor jedem `nixos-rebuild`/`deploy-*.sh`: `git add -A`.

### „boot.loader.grub.devices muss gesetzt sein" (Assertion)
- **Ursache:** Irgendwo wird GRUB aktiv, obwohl das Gerät über systemd-boot bootet.
- **Fix:** explizit `boot.loader.grub.enable = false;` (steht in der Host-Config).

### Build bricht mit Assertion zu `virtualisation.libvirtd.qemu.ovmf` ab
- **Ursache:** Die Option `…qemu.ovmf` wurde in 26.05 **entfernt** (OVMF/UEFI für Gäste ist automatisch dabei).
- **Fix:** Option ersatzlos **streichen**.

### „Error: unsupported locales detected: 1/UTF-8" beim nixos-install ✓ erlebt (Kollegen-Laptop)
- **Symptom:** `nixos-install` bricht im glibc-locales-Build ab: erst eine lange Liste aller gültigen
  Locales, dann `Error: unsupported locales detected: 1/UTF-8`; die nixos-system-Derivation
  scheitert mit „1 dependency failed".
- **Ursache:** Bei der (früher freien) Locale-Abfrage des Installers wurde „1" eingegeben — im
  Nummern-Rhythmus der übrigen Menüs naheliegend. Der Wert landete ungeprüft als
  `i18n.defaultLocale = "1"` in `modules/desktop.nix`; NixOS leitet daraus den
  `supportedLocales`-Eintrag `1/UTF-8` ab, den glibc nicht kennt. **Grep-Falle** bei der Suche:
  die Option heißt `defaultLocale` (großes L) — case-sensitives `grep "defaultlocale"` findet
  nichts, `grep -in locale modules/desktop.nix` schon.
- **Fix (sofort, laufende Live-Session):** in `~/nixos-config/modules/desktop.nix` den Wert auf
  z.B. `de_DE.UTF-8` korrigieren, dann `git add -A` und
  `sudo env TMPDIR=/mnt/tmp nixos-install --flake ".#<host>" --no-root-passwd` erneut ausführen.
  Wurde das ISO bereits neu gebootet: `install.sh` einfach nochmal laufen lassen.
- **Fix (dauerhaft):** `install.sh` validiert seither **alle** Abfragen mit Re-Prompt (Hostname
  RFC-1123, Benutzername POSIX, Zeitzone gegen die tzdata, xkb-Format); die Locale ist jetzt ein
  Menü mit „eigene"-Option + Format-Check `sprache_LAND.UTF-8[@modifier]`.

---

## B. SSH & git

### `Enter passphrase for key '…/id_ed25519'` bei JEDEM ssh ✓ erlebt
- **Ursache:** ssh-agent läuft (`programs.ssh.startAgent`), ist aber **leer**; ohne `AddKeysToAgent`
  lädt ssh den Key nicht in den Agent → liest jedes Mal die Datei.
- **Fix:** sofort `ssh-add` (Passphrase 1×, dann Ruhe für die Sitzung). Dauerhaft: `AddKeysToAgent yes`
  in `programs.ssh.extraConfig` (Host) → Key landet beim 1. Connect automatisch im Agent.

### `dev@192.168.122.234: Permission denied (publickey)` ✓ erlebt
- **Ursache:** Der `ssh dev@…`-Befehl wurde **aus der VM heraus** abgesetzt — die VM hat keinen Key.
- **Fix:** **vom Host** verbinden, nicht aus der VM-Shell.

### „WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED" beim ssh in die VM
- **Ursache:** Die dev-VM ist near-stateless → der **SSH-Host-Key ändert sich bei jedem Deploy**.
- **Fix:** ist bereits gelöst — `deploy-dev-vm.sh` macht `ssh-keygen -R <ip>`, und die Host-ssh_config
  hat `StrictHostKeyChecking accept-new`. Bleibt es doch mal hängen: manuell `ssh-keygen -R 192.168.122.234`.

### git push/clone in der VM will Passwort/Token
- **Ursache:** HTTPS-URL statt SSH; oder Key nicht im Agent (Forwarding läuft leer).
- **Fix:** **SSH-URL** nutzen (`git@github.com:…`), auf dem Host vorher `ssh-add`. Gegencheck in der VM:
  `ssh-add -l` muss den **Host-Key** zeigen; `ssh -T git@github.com` → „Hi <dein-github-name>!".

---

## C. dev-VM: Boot, Mount, Konsole

### Gast landet im „Emergency Mode" / findet die Platte nicht
- **Ursache:** virtio-Treiber fehlen im initrd.
- **Fix:** `imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];` in der Gast-Config.

### `dev` kann nicht in sein `~` schreiben (frisches Volume gehört root) ✓ erlebt (früher)
- **Ursache:** `nofail`-Mount nimmt `/home/dev` aus der `local-fs.target`-Ordnung → `systemd-tmpfiles`
  läuft **vor** dem Mount und fasst den noch verdeckten Mountpunkt an.
- **Fix:** oneshot-Service mit `after`/`requires = [ "home-dev.mount" ]` + `ConditionPathIsMountPoint`,
  der `chown dev:users /home/dev` **nach** dem Mount macht (steht in der Gast-Config).

### `virsh console dev-vm` „sieht aus wie der Host"
- **Klarstellung (kein Fehler):** Der Prompt `[dev@dev-vm]` auf der seriellen Konsole **ist** die VM.
  SSH muss trotzdem **vom Host** kommen (eigenes Terminal). Raus aus der Konsole: `Strg-]`.

---

## D. Updates & Notify-Timer

### `systemctl --user start … nixos-update-check` → „nichts passiert" ✓ erlebt
Drei legitime Gründe, alle **kein Fehler**. `--no-block` heißt ohnehin: auf der Kommandozeile bleibt es
still. Eindeutig per Trace (läuft in deiner Shell, die hat Session-Bus & Display):
```bash
SCRIPT="$(systemctl --user cat nixos-update-check | sed -n 's/^ExecStart=//p')"
bash -x "$SCRIPT"
```
Wo der Trace endet, sagt die Ursache:
- **Timer selbst ist gestoppt** (der Trace läuft, aber der Stunden-Takt fehlt) → **Snooze aktiv**:
  seit 2026-07-12 läuft Snooze rein über systemd — Stunden-Timer gestoppt, transienter Wecker
  `nixos-update-snooze` hält die Weckzeit (kein State-File mehr). Sichten/aufheben:
  ```bash
  systemctl --user list-timers                       # Wecker + Weckzeit sichtbar?
  systemctl --user stop nixos-update-snooze.timer    # Snooze aufheben …
  systemctl --user start nixos-update-check.timer    # … und Stunden-Takt wieder an
  ```
- **`[ <rev> = <rev> ]` → `exit 0`** → **kein Update**: lokale nixpkgs-Revision == upstream. Korrekt.
  Gegencheck: `bash update-all.sh --dry-run` (bewegt sich der Lock?).
- **`upstream=` leer → `exit 0`** → offline/Timeout beim `git ls-remote`. Korrekt (still raus).
- **Trace bleibt bei `notify-send` stehen** → Benachrichtigung erscheint (siehe nächste Punkte).

### Benachrichtigung verschwindet nach Sekunden ✓ erlebt
- **Ursache:** Plasma schiebt Benachrichtigungen „normaler" Dringlichkeit nach Sekunden ins Archiv
  (Glocken-Symbol im Tray — der Klick auf den Knopf zählt dort weiterhin).
- **Fix:** `--expire-time=0` im `notify-send`-Aufruf (steht im Check-Skript) → bleibt stehen, bis
  reagiert; `timeout 3600` im Skript ist das Sicherheitsnetz (1 h keine Reaktion = ignoriert —
  der Stunden-Timer erinnert beim nächsten Takt erneut; früher galt das fälschlich als „morgen").

### `notify-send: command not found` ✓ erlebt
- **Ursache:** `libnotify` nicht im PATH. **Für den Timer egal** — das Skript bündelt `git`/`jq`/
  `libnotify`/`coreutils` via `makeBinPath`.
- **Fix (nur für manuelle Tests):** `nix shell nixpkgs#libnotify --command bash -c '… notify-send …'`
  oder `libnotify` in `systemPackages` (ist eingebaut).

### Tut der Hintergrund-Service den Notification-Daemon erreichen? ✓ getestet (positiv)
- **Test in der Service-Umgebung** (nicht in der interaktiven Shell):
  ```bash
  NS=/nix/store/…-libnotify-…/bin/notify-send       # exakten Pfad aus dem bash -x-Trace nehmen
  systemd-run --user --wait --pipe "$NS" --app-name=NixOS --expire-time=0 --action=now=Jetzt "Test" "…"
  ```
  Erscheint die Benachrichtigung (und der geklickte Key steht in der `systemd-run`-Ausgabe), ist der
  User-Service-Pfad ok → der stündliche Lauf feuert, sobald es echte Updates gibt.

### `notify-send`-Knöpfe: liefern sie den Key? ✓ verifiziert
- **Erwartung:** Klick liefert den Key auf stdout (`now`/`1h`/`8h`/`1d`, Exit 0). Die `case`-Logik fängt
  zusätzlich die Labels ab (Fallback). Isolierter, ungefährlicher Test:
  ```bash
  nix shell nixpkgs#libnotify --command bash -c 'c=$(timeout 120 notify-send --expire-time=0 \
    --action=now=Jetzt --action=1h="In 1 Stunde" "TEST" "klick"); printf "[%s] exit %s\n" "$c" "$?"'
  ```

### Nach `nixos-rebuild` kennt der User-Manager die neue Unit/das neue Skript nicht
- **Fix:** `systemctl --user daemon-reload` (oder ab-/anmelden).

### `sudo: /run/current-system/sw/bin/sudo muss dem Benutzer mit UID 0 gehören und das »setuid«-Bit gesetzt haben` ✓ erlebt
- **Symptom:** Die Benachrichtigung „Jetzt aktualisieren" (oder das Update-Icon) startet `update-all.sh`;
  `nix flake update` läuft noch durch, aber `sudo nixos-rebuild switch` bricht sofort mit dieser Meldung
  ab. Im interaktiven Terminal läuft derselbe Befehl problemlos.
- **Ursache:** NixOS hat **zwei** sudo — das echte setuid-sudo unter `/run/wrappers/bin/sudo` und eine
  nicht-setuid-Kopie unter `/run/current-system/sw/bin/sudo`. Interaktiv steht `/run/wrappers/bin` vorn
  im PATH → richtig. Im **Notification-/User-Service-Kontext** (so startet die Benachrichtigung das
  Skript) fehlt dieser Pfad vorn → der Aufruf trifft die nicht-setuid-Kopie, die ohne setuid-Bit nicht
  root werden kann. Kein kaputtes sudo, sondern ein PATH-Problem. (Fiel erst auf, als zum ersten Mal ein
  echtes Update den Flow bis zum `sudo`-Schritt trieb.)
- **Fix:** in `update-all.sh` direkt nach `set -euo pipefail`:
  ```bash
  export PATH="/run/wrappers/bin:$PATH"
  ```
  Gegencheck: `type -a sudo` zeigt interaktiv `/run/wrappers/bin/sudo` ZUERST; `ls -l /run/wrappers/bin/sudo`
  ist `-r-s--x--x root` (setuid). Derselbe Einzeiler gehört in die schlanke `update-all.sh`, die
  `install.sh` für frische Maschinen erzeugt.

### „Jetzt aktualisieren" geklickt, aber nicht durchgezogen → keine Erinnerung mehr ✓ erlebt
- **Symptom:** Nach „Jetzt aktualisieren" und Abbruch (Fenster zu / Strg-C / Rebuild-Fehler) kommt
  **keine** neue Update-Benachrichtigung mehr — obwohl der Host gar nicht aktualisiert wurde.
- **Ursache:** **Nicht** der Snooze (der „Jetzt"-Pfad setzt keinen). `update-all.sh` ruft als
  **erstes** `nix flake update` → `flake.lock` ist sofort gebumpt; der Commit kommt erst **nach**
  erfolgreichem Rebuild. Bricht es dazwischen ab, bleibt ein gebumptes-aber-nicht-gebautes `flake.lock`
  zurück. Der Check verglich früher genau diese Datei mit upstream → `localrev == upstream` → „kein
  Update" → still. (Der sudo-PATH-Bug oben war der häufigste Auslöser des Abbruchs.)
- **Fix (zweiteilig, ergänzen sich):**
  1. **Check gegen das laufende System:** `nixos-update-check` vergleicht jetzt
     `nixos-version --json | jq -r .nixpkgsRevision` (womit der Host **läuft**) mit upstream, nicht mehr
     `flake.lock`. Ein halbfertiger Bump ist damit egal — die Erinnerung bleibt, bis der Host wirklich
     gebaut ist. Fallback auf `flake.lock` nur bei dirty build.
  2. **Rollback in `update-all.sh`:** Ein `trap` verwirft den Bump (`git checkout -- flake.lock`), wenn
     vor dem erfolgreichen Rebuild abgebrochen wird → kein verwaister Bump (den zöge ein späteres
     `rebuild`/`deploy` sonst ungewollt mit). Nach erfolgreichem Rebuild **kein** Rollback.
- Beides gehört auch in die von `install.sh` erzeugten `host-updates.nix` + `update-all.sh`.
- Gegencheck: `nixos-version --json | jq -r .nixpkgsRevision` zeigt die 40-stellige SHA des laufenden
  Systems (nicht `null`/leer).

### Update-Erinnerung fehlt komplett nach frischer Installation (kein Icon, nie eine Meldung) ✓ erlebt
- **Symptom:** Auf einem frisch per `install.sh` aufgesetzten Host gibt es weder das Startmenü-Icon
  „NixOS aktualisieren" noch jemals eine Update-Benachrichtigung.
- **Ursache:** Der Installer-Prompt „Update-Erinnerung installieren?" hatte bis 2026-07-12 den
  Default **N** — Enter (durchgeklickt) hieß **nein**, ohne jede weitere Meldung: weder
  `modules/host-updates.nix` noch `update-all.sh` werden dann erzeugt, das Modul fehlt in der
  Host-Config. Seit 2026-07-12: Default **J** plus Summary-Zeile am Skriptende.
- **Diagnose:**
  ```bash
  ls ~/nixos-config/modules/host-updates.nix ~/nixos-config/update-all.sh
  grep -n host-updates ~/nixos-config/hosts/*/configuration.nix
  systemctl --user list-timers nixos-update-check.timer
  ```
  Fehlen die Dateien → Prompt-Falle (dieser Eintrag). Existieren sie und nur die Benachrichtigung
  blieb aus: direkt nach frischer Installation ist `localrev == upstream` — es kommt schlicht nichts,
  bis `nixos-26.05` weiterwandert; das Icon müsste aber trotzdem da sein.
- **Nachrüsten ohne Neuinstallation:**
  ```bash
  cd ~/nixos-config
  # 1) beide Dateien aus dem Basis-Payload uebernehmen (s. README-payload.md):
  #      modules/host-updates.nix   und   update-all.sh (chmod +x)
  # 2) in hosts/<host>/configuration.nix bei imports ergaenzen:
  #      ../../modules/host-updates.nix
  sudo nixos-rebuild switch --flake .#<host>
  systemctl --user daemon-reload   # falls die Sitzung schon lief
  ```
  Danach: Icon im Startmenü, `systemctl --user list-timers` zeigt `nixos-update-check`. (Hintergrund:
  Kopf von `modules/host-updates.nix`.)

### Firmware-Abschnitt (fwupd): Erstlauf-Verifikation — offen
- `update-all.sh` Abschnitt 5: `fwupdmgr refresh --force` → `get-updates` (Exit 0 = Updates da) →
  `[j/N]`-Gate → `sudo fwupdmgr update -y`. **`-y` bejaht auch die Reboot-Frage** → Bestätigen heißt
  sofortiger Neustart (gewollt; deshalb letzter Abschnitt, `--host-only` überspringt komplett).
- **Beim ersten Echtlauf prüfen:** (a) `fwupdmgr get-devices` listet „System Firmware" → LVFS-Support
  des Geräts bestätigt; (b) exaktes Prompt-Verhalten von `-y` der installierten fwupd-Version
  (Report-Upload-Frage?); (c) nach dem Reboot `fwupdmgr get-history`. LVFS hinkt Dell gelegentlich
  eine Version hinterher → bei Security-BIOS Gegencheck auf dell.com.


### update-all meldet am Ende „VM-Images noch auf altem Stand" ✓ erwartet — kein Fehler
- **Symptom:** Sammel-Hinweis am Skriptende nennt eine VM samt Nachhol-Befehl.
- **Einordnung:** Die VM **lief** während des Updates (wird bewusst nie angefasst — keine
  abgerissene Zed-Session, kein unterbrochenes Keystone-Signing) oder ihr Deploy schlug fehl.
- **Fix:** Session beenden, dann den angezeigten `bash deploy-*-vm.sh` nachschieben — oder
  einfach den nächsten `update-all`-Lauf machen: der Stand-Marker
  (`/var/lib/libvirt/images/<vm>.flake-rev`) hält die VM fällig, bis wirklich deployt wurde.

### Rabby-Bump im update-all übersprungen („Hash nicht ermittelbar" / „Pin-Muster nicht eindeutig")
- **Symptom:** Das `[j/N]`-Gate wurde bestätigt, aber der automatische Bump bricht mit einer
  der beiden Warnungen ab; die Gast-Config bleibt unverändert.
- **Ursache:** Download der Release fehlgeschlagen (offline, GitHub-Störung) — oder die
  Eindeutigkeits-Guards greifen, weil `hosts/browser-vm/configuration.nix` nicht mehr genau
  **ein** `rabbyVersion`- und **ein** `hash = "sha256-…"`-Muster trägt (das Skript editiert
  dann bewusst nichts blind).
- **Fix (der dokumentierte manuelle Weg aus dem Config-Kopf):** `rabbyVersion` bumpen,
  `hash = lib.fakeHash` setzen, deployen — der Build bricht ab und nennt den echten Hash
  („got: sha256-…") → eintragen, committen. Der Stand-Marker sorgt danach von selbst dafür,
  dass `update-all` nichts doppelt baut.

### Nach einem Update ist etwas kaputt — wo steht, was sich geändert hat?
- **Session-Log** (seit 2026-07-13): jeder `update-all.sh`-Lauf landet komplett unter
  `~/.local/state/update-all/<Datum>_<Host>.log` (die letzten 20 bleiben; lesen mit `less -R`,
  ANSI-Farben sind drin). Enthält Diff, alle Gate-Antworten, VM-Deploys, Firmware — und bei
  Abbruch die Fehlermeldung. Am Anfang steht der **Vorzustand** (`systemctl --failed` vor dem
  Update): trennt „neu kaputt" von „war schon kaputt".
- **git-Chronik:** `git log -- flake.lock` — der Commit-Body trägt den Paket-Diff, der Host steht
  im Betreff (Diff ist host-spezifisch). Nach `git push` von jedem Gerät aus lesbar — auch wenn
  die Maschine nicht mehr hochkommt.
- **Retro-Diff zwischen beliebigen Generationen** (solange keine GC lief):
  ```bash
  nixos-rebuild list-generations
  nvd diff /nix/var/nix/profiles/system-47-link /nix/var/nix/profiles/system-48-link
  ```
- **Rollback:** `sudo nixos-rebuild switch --rollback` — oder alte Generation im Bootmenü wählen.
- Die Smoke-Checks (2b) warnen nur, brechen nie ab; `check-*.sh` sind selbst-guardend (Host ohne
  vfio/libvirt → still). Mechanik: `README-update-all.md`.


---

## E. GPU / Vulkan (dev-VM) — venus **geparkt**

### `VK_ERROR_OUT_OF_HOST_MEMORY` bei `vkCreateInstance` (venus im Gast) — geparkt
- **Symptom:** venus-Vulkan im Gast scheitert, kein Gerät enumeriert.
- **Ursache:** Mesa-26.1-venus ↔ virglrenderer-1.3 zu unreif.
- **Stand:** **geparkt**, Zed läuft auf lavapipe (Software-Vulkan). Wiedervorlage bei reiferem Stack
  oder über `rutabaga`/gfxstream. Test-XML: `dev-vm-venus.xml` (nicht aktiv).

### `failed to initialize venus renderer` — geparkt
- **Ursache:** libvirts seccomp-Sandbox (`-sandbox …,spawn=deny`) verbietet QEMU, den
  `virgl_render_server` zu spawnen (venus braucht ihn als eigenen Prozess).
- **Workaround (war nötig, dann zurückgenommen):** `seccomp_sandbox = 0` via
  `virtualisation.libvirtd.qemu.verbatimConfig` — host-weite Härtungs-Abwägung; mit venus geparkt.

### „Unable to find a Vulkan driver" (waypipe/Zed-Start) ✓ gelöst
- **Ursache:** Rust-waypipe initialisiert beim Start **zwingend** Vulkan (für DMABUF).
- **Fix:** `hardware.graphics.enable = true` → Mesa/lavapipe (CPU-Vulkan, kein echtes GPU nötig).

### radv-Fehlerlärm / „Unsupported GPU"-Dialog in Zed ✓ gelöst
- **Fix (Launcher `zed-dev`):** `VK_DRIVER_FILES=…/lvp_icd.x86_64.json` (lavapipe erzwingen) +
  `ZED_ALLOW_EMULATED_GPU=1`. **Wichtig:** `VK_DRIVER_FILES`, **nicht** das alte `VK_ICD_FILENAMES`
  (Vulkan-Loader 1.4+ ignoriert es).

---

## F. Netzwerk

### LAN tot nach Kabel-Wechsel (Intel I219-LM / `e1000e`) ✓ erlebt → net-VM verworfen
- **Symptom:** Nach Carrier-Wechsel handelt der PHY instabil aus (`10 Mbps Half` → Down → spät
  `1000 Full`); „Link up", aber **kein** Verkehr (sogar ARP/DHCP scheitern, DHCP-Timeout im 45-s-Takt).
- **Ursache:** Hardware-Bug der I219-LM; **kein** NetworkManager-/DHCP-/`rp_filter`-/ASPM-Problem.
- **Fix (zuverlässig):** `nmcli device connect enp0s31f6` (voller Controller-Reset). Robuster Auto-Fix
  wäre ein NetworkManager-Dispatcher bei Link-Up — bewusst nicht eingebaut (Alltag = WLAN/Tethering).
- **Konsequenz:** Die net-VM (WLAN-Passthrough als Gateway) ist deswegen **verworfen**; Netz-Isolation
  via externer Reise-Firewall / Tethering.

### VMs ohne DNS direkt nach dem nftables-Umstieg ✓ erlebt (2026-07-21) — im Modul behoben
- **Symptom:** Nach dem Switch auf `networking.nftables.enable` scheitern in **beiden** VMs alle
  namensbasierten Zugriffe still (`getent hosts` leer, `curl https://example.com` Timeout);
  IP-basierte Proben verhalten sich dagegen exakt wie von der Isolations-Matrix erwartet.
- **Ursache:** Mit dem nftables-Backend liegen libvirts eigene ACCEPT-Regeln (iptables-nft,
  `table ip filter`) und die NixOS-Firewall (`table inet nixos-fw`, Default-Drop im input) in
  **getrennten Tabellen** — Drop gewinnt tabellenübergreifend, und `nixos-fw` verwarf die
  DNS-/DHCP-Anfragen der VMs an die Bridge-`.1`. Unter dem alten iptables-Backend teilten sich
  beide dieselbe Tabelle, libvirts Accepts griffen vor dem Drop. (Derselbe Mechanismus, den
  die Isolierung bewusst nutzt — hier einmal in die Gegenrichtung.)
- **Fix (in `modules/vm-net-isolation.nix`):** interface-gebundene Freigaben
  `networking.firewall.interfaces."virbr-*"` für 53 (udp+tcp) und 67/udp — **nur** auf den
  VM-Bridges, kein LAN-Interface betroffen; alles jenseits von DNS/DHCP begrenzt weiterhin
  die eigene `input-vm-bridges`-Chain.
- **Schnelldiagnose bei Wiederauftreten:** `curl -m5 -skI https://1.1.1.1` aus der VM geht
  (Forward intakt), `getent hosts example.com` bleibt leer → DNS-Pfad, nicht Egress.

### VM erreicht LAN / Host / andere VM nicht — das ist das Soll (seit 2026-07-21)
- **Symptom:** Aus dev-vm oder browser-vm schlagen `ping <lan-ip>`, Zugriffe auf Host-Dienste
  oder auf die jeweils andere VM fehl; auch `ping` auf die Bridge-`.1` antwortet nicht.
- **Einordnung:** Kein Fehler — genau das erzwingt `modules/vm-net-isolation.nix`
  (Policy + Design: Kopf von `modules/vm-net-isolation.nix`; Soll-Matrix: `README-hardening.md`). VM→Host ist nur DNS/DHCP.
- **Wirklich nötige Ausnahme?** Dokumentierter Options-Override im Host-Ordner
  (`hardening.vmNetIsolation.<vm>.allowedTcpPorts` + Kommentar wozu) — LAN-Ziele bleiben
  auch damit gesperrt (RFC-1918-Drop greift vor den Port-Accepts).

### VM: Verbindung zu einem Internet-Port scheitert (z. B. `curl http://…` in der dev-vm)
- **Symptom:** `curl -m5 https://…` geht, derselbe Host über einen anderen Port (etwa 80,
  6443, IMAP …) läuft in den Timeout.
- **Ursache:** Der Port steht nicht in der Egress-Allowlist der VM (dev-vm: 22/443;
  browser-vm: 80/443 tcp + 443 udp). Gegencheck: die Drop-Counter in
  `sudo nft list table inet vm-isolation` zählen bei jedem Versuch hoch.
- **Fix:** Bewusste, kommentierte Ausnahme im Host-Ordner (s. o.) — nie das Modul editieren.

### Gast-Journal meldet timesyncd-/NTP-Fehler ✓ erwartet — Kosmetik
- **Symptom:** In den VMs loggt `systemd-timesyncd` erfolglose NTP-Versuche
  (123/udp ist bewusst nicht freigegeben).
- **Einordnung:** Die Gast-Uhr kommt über kvm-clock/RTC vom Host und bleibt korrekt —
  TLS/Zertifikate funktionieren. Kein Handlungsbedarf; Freigabe von 123/udp wäre eine
  dokumentierte Ausnahme, bringt aber nichts.

---

## G. Claude-Code (dev-VM)

### Login: hängt der Geräte-Flow am localhost-Callback? ✓ geklärt — nein
- **Beobachtung:** `claude` zeigt eine URL mit `redirect_uri=…platform.claude.com/oauth/code/callback`
  und `code=true` → das ist der **Code-Paste-Flow**, nicht der localhost-Callback → **headless-tauglich**,
  hängt nicht.
- **Ablauf:** URL in den **Host-Browser**, anmelden, **Authorization-Code** kopieren, im VM-Terminal in
  den wartenden Prompt einfügen. Auth landet in `/home/dev` und **überlebt** Redeploys (Persistenz-Volume).

### Nach Redeploy fragt Claude-Code erneut „trust this folder?"
- **Klarstellung (kein Fehler):** Der Workspace-Trust-Dialog kommt einmal pro Ordner, den Claude-Code
  zum ersten Mal sieht — **kein** Login-/Persistenz-Problem. Mit `1. Yes, I trust this folder` bestätigen.

---

## H. Zed / waypipe (dev-VM)

### Paste in Zeds Terminal „geht nicht" ✓ geklärt — Shortcut
- **Symptom:** Host→VM-Paste scheitert scheinbar (z. B. Claude-Code-Auth-Code einfügen);
  Gegenrichtung VM→Host funktioniert.
- **Ursache:** Im Terminal-Kontext wird `Ctrl+V` als Steuerzeichen an die Shell durchgereicht —
  Paste ist dort `Ctrl+Shift+V` (Standard bei Linux-Terminalen). Im Editor-Bereich pastet
  `Ctrl+V` normal. Die waypipe-Clipboard-Leitung selbst ist bidirektional in Ordnung.

---

## I. dGPU / NVIDIA (PRIME Offload + RTD3, seit 2026-07-16)

### dGPU steht in D0 statt D3cold ✓ erlebt (False Alarm — zu früh gemessen)
- **Symptom:** `cat /sys/bus/pci/devices/0000:01:00.0/power_state` zeigt `D0` im vermeintlichen
  Leerlauf.
- **Erste Regel:** Direkt nach dem Login braucht der Runtime-PM-Pfad bis zu ~1 min; und
  `nvidia-smi` **weckt selbst die Karte** — nie als „Leerlauf-Messung" verwenden, danach
  10–20 s warten.
- **Diagnosekette** (in dieser Reihenfolge; so am 2026-07-16 verifiziert):
  ```bash
  cat /sys/bus/pci/devices/0000:01:00.0/power/control        # MUSS 'auto' sein (sonst: udev-Regeln pruefen)
  grep -i dynamicpower /proc/driver/nvidia/params            # MUSS 'DynamicPowerManagement: 2' zeigen
  sudo cat /proc/driver/nvidia/gpus/0000:01:00.0/power       # 'Runtime D3 status: Enabled (fine-grained)'
  sudo fuser -v /dev/nvidia* 2>/dev/null                     # haelt ein Prozess die Karte offen?
  sleep 60 && cat /sys/bus/pci/devices/0000:01:00.0/power_state   # dann erst bewerten
  ```
- **Gesunder Zustand:** `control: auto`, `runtime_status: suspended`, `Video Memory: Off`,
  `power_state: D3cold` — auch bei laufendem Steam-Client/-Download (rendert auf der iGPU).

### HDMI-Audio-Funktion (01:00.1) fehlt im sysfs / auf dem PCI-Bus ✓ erlebt (kein Fehler)
- **Symptom:** `/sys/bus/pci/devices/0000:01:00.1/…` existiert nicht; `lspci -d 10de:2291` leer.
- **Klarstellung:** In **D3cold** ist der Slot stromlos — Teilfunktionen verschwinden komplett
  vom Bus. Das ist der **Beweis** des Stromsparens, kein Defekt. Taucht wieder auf, sobald die
  Karte geweckt wird. (Gleiche Ursache wie der check-vfio-False-Positive, s.
  `README-check-vfio.md`.)

### `error: 'glxinfo' has been renamed to/replaced by 'mesa-demos'` ✓ erlebt
- **Ursache:** nixpkgs-Umbenennung; das Paket `glxinfo` ist ein throw-Alias.
- **Fix:** `nvidia-offload nix shell nixpkgs#mesa-demos --command glxinfo -B | grep -i renderer`

---

## J. Display / USB-C / Monitore

### MST-Daisy-Chain: nur Monitor 1 geht (hohe Bandbreite) ✓ erlebt → Fix: Mainline-Kernel
- **Symptom:** USB-C-Daisy-Chain (Monitor 1 → DP-Out → Monitor 2); nur der erste Monitor wird
  erkannt. Dieselbe Kette läuft unter **Windows**; unter NixOS **und** Kubuntu fehlt Monitor 2
  (→ distro-unabhängig, Kernel-Ebene). Eine Kette mit **weniger** Bandbreite läuft; ein
  **Einzelmonitor** mit gleicher/höherer Bandbreite über denselben Port läuft ebenfalls.
- **Ursache:** i915-Schwäche bei der **Bandbreiten-Verteilung/DSC über MST** auf Meteor Lake im
  LTS-Kernel (`pkgs.linuxPackages`). Die MST/DSC-Fixes kamen erst in neuere Mainline-Kernel.
- **Diagnosekette** (Kette angesteckt; so am 2026-07-20 verifiziert):
  ```bash
  for f in /sys/class/drm/card*/card*-*/status; do echo "$f: $(cat "$f")"; done
  kscreen-doctor -o
  sudo dmesg | grep -iE "mst|link train|dsc" | tail -30
  ```
  Gesund: **beide** externen Connectoren `connected` (je nach Kernel als `DP-3`/`DP-4` oder als
  MST-Unterconnectoren `DP-3-x`) und beide Monitore in `kscreen-doctor -o`. Kaputt (LTS): nur der
  erste externe Connector taucht auf. Zeigt kscreen einen Connector `connected`, aber `disabled`,
  fehlt nur das Aktivieren: Systemeinstellungen → Anzeige oder
  `kscreen-doctor output.DP-4.enable output.DP-4.position.<x>,<y>` (kscreen merkt sich die
  Kombination danach).
- **Fix:** Mainline-Kernel — seit 2026-07-20 **fleet-weiter Default** in `modules/desktop.nix`
  (`pkgs.linuxPackages_latest`; Entscheidung + Abwägung: Kopf von `modules/desktop.nix`).
  Verifiziert auf dem Referenzgerät mit Kernel 7.1.4: beide Monitore sofort da (2560×1440@75 +
  3440×1440). `install.sh` fragt die Wahl bei Neuinstallationen ab (Default J).
  **Achtung — der Fix ist plattformabhängig:** auf dem Dell Latitude 5550 (Referenzgerät) behebt Mainline
  das Fehlerbild vollständig; auf dem ThinkPad L16 **nicht** (s. eigener Eintrag unten,
  2026-07-22). Die Betriebsgrenze „max. 2× 2K per Chain" gilt deshalb flotten­weit als
  konservative Regel.
- **Grep-Falle bei der Diagnose:** MST-Connector-Namen (`DP-5`, `DP-6`, …) sind **dynamisch** —
  bei jeder Topologie-Enumeration (Replug!) werden sie neu angelegt und hochgezählt. Nach einem
  Replug existiert `DP-5` evtl. nicht mehr (`Output … not found`), stattdessen `DP-7`/`DP-8`.
  Namen deshalb **nie in Skripte hartkodieren**; immer frisch aus `kscreen-doctor -o` bzw.
  `/sys/class/drm/` lesen.
- **Nebenbefund (erwartet, kein Fehler):** die **USB-Peripherie** fremder Monitore/Docks
  (Hubs/Ethernet/Tastatur/Maus, z. B. `0bda:5411`, `0bda:8153`, `17ef:6099/6019`) meldet
  `Device is not authorized for usage` — das ist **USBGuard** (Default-Block). Betrifft nur USB,
  nie das Videosignal. Whitelist über den `usbguard-sync.sh`-Workflow auf dem **jeweiligen** Host
  nachziehen. Für wandernde Dock-Peripherie: **VID:PID-only-Regeln** ohne `via-port`/
  `parent-hash`/`name` — Begründung und die „Lenogo"-Lektion: README-hardening.md,
  „Neues Gerät erlauben".

### MST-Daisy-Chain >2×2K auf dem ThinkPad L16: auch mit Mainline instabil ✓ erlebt (2026-07-22) → Betriebsgrenze
- **Gerät:** Lenovo ThinkPad L16 (Meteor Lake, Core Ultra 5; zweites Testgerät der Flotte). Lief ab Installation auf Mainline 7.1.4 (Installer-Frage mit J
  beantwortet) — derselbe Kernel-Stand, der auf dem Referenzgerät den Fix brachte.
- **Symptom:** Dieselbe Chain (QHD-Monitor → DP-Out → UWQHD 3440×1440), die am Referenzgerät stabil
  läuft, ist am L16 nicht zuverlässig: nach frischem Boot werden zeitweise **alle** Displays
  enumeriert (inkl. UWQHD mit vollen Modi), nach USB-C-Replug findet teils **gar keine**
  DP-Alt-Mode-Aushandlung mehr statt (alle DRM-Connectoren `disconnected`, keine
  typec/ucsi-Events im dmesg — nur die USB-Geräte des Docks enumerieren).
- **Ausgeschlossen wurde:** physischer Layer (180°-Stecker-Test, Kabeltausch — beides ohne
  Änderung), BIOS-Optionen (Thunderbolt an, kein Security-Level vorhanden), Firmware
  (fwupd meldet aktuell), `boltd` (Chain ist reiner DP-Alt-Mode, **kein** TBT-Gerät auf dem
  Bus — `services.hardware.bolt.enable = true` wurde gesetzt, war aber nachweislich **nicht**
  die Ursache und kann als harmlos drinbleiben), KWin (der Kernel selbst sah nach dem Replug
  nichts mehr).
- **Wichtige Hardware-Eigenheit:** Nur **einer** der beiden USB-C-Ports des L16 ist
  video-/USB4-fähig (im dmesg: nur `typec port1` hat eine `usb4_port`-Bindung). Die Chain
  gehört immer an diesen Port; am anderen enumeriert nur USB, nie Video.
- **Verifiziert läuft (L16, Mainline):** 2× 2K per Daisy-Chain — stabil (Test vor der
  Debug-Session). 2× 2K auf **LTS** ist am Referenzgerät (vor 2026-07-20) und einem weiteren Testgerät
  der Flotte belegt; für das L16 selbst gibt es keine LTS-Messung (lief nie auf LTS).
- **Betriebsgrenze (Empfehlung, dokumentiert):** per MST-Daisy-Chain **max. 2× 2K** — deckungs-
  gleich mit der iiyama-Herstellerempfehlung für die verbauten Monitore. Bedarf darüber:
  **TB4-Dockingstation** (DisplayPort-Tunneling über USB4 statt MST-Kaskade durch Monitor-Hubs —
  strukturell der robustere Pfad) **oder** Dell Latitude 5550 bei gleicher CPU-Generation
  (nachweislich nativ stabil auf dem Fleet-Kernel).
- **Randnotiz mkForce:** Das L16-Installer-Repo definiert den Kernel in seinem eigenen
  `modules/desktop.nix`; ein Host-Override braucht dort `lib.mkForce` (sonst „defined multiple
  times"). Unser Test-Override auf `linuxPackages_latest` war rückblickend ein **No-op mit
  gleichem Wert** — der Kernel war nie das Delta. Prioritäten-Mechanik: `nixos-cheatsheet.md`
  §13.

### MST-Monitor „aktiv, aber schwarz" → disable/enable erzwingt frisches Link-Training ✓ erlebt (2026-07-22)
- **Symptom:** kscreen/Systemeinstellungen zeigen den Monitor als **aktiv**, das Panel bleibt
  aber schwarz. Auflösung/Refreshrate reduzieren ändert **nichts**.
- **Ursache:** Der MST-Payload (VCPI-Zeitschlitz) zum Branch wurde nie sauber etabliert —
  z. B. weil die Erst-Aktivierung in einem Bandbreiten-Grenzfall scheiterte (2560×1440@74,92
  parallel zum UWQHD). Der Compositor merkt sich „aktiv" und **modifiziert** fortan nur den
  defekten Zustand, statt ihn neu aufzubauen — deshalb hilft auch die Mode-Reduktion nicht.
- **Fix:** den Output explizit aus- und wieder einschalten — das gibt den Payload frei und
  erzwingt frisches Link-Training samt neuer VCPI-Allocation. **Sequenziell** aktivieren
  (ein Branch nach dem anderen), konservativ mit 60 Hz starten:
  ```bash
  kscreen-doctor -o                                   # AKTUELLE Connector-Namen ermitteln (dynamisch!)
  kscreen-doctor output.<QHD>.disable output.<UWQHD>.disable
  sleep 3
  kscreen-doctor output.<QHD>.enable output.<QHD>.mode.<60Hz-Modus>
  sleep 2
  kscreen-doctor output.<UWQHD>.enable output.<UWQHD>.mode.<60Hz-Modus> output.<UWQHD>.position.<x>,0
  ```
- **Tiefendiagnose bei Bedarf** (i915 loggt MST-Details nur mit DRM-Debug; Reihenfolge:
  erst Debug an, dann der Toggle, dann lesen — sonst bleibt der grep leer):
  ```bash
  echo 0x104 | sudo tee /sys/module/drm/parameters/debug
  # … disable/enable wie oben …
  sudo dmesg | grep -iE "mst|vcpi|payload|link train|dsc" | tail -60
  echo 0 | sudo tee /sys/module/drm/parameters/debug
  ```
  (`SSDsc` in der zram-Swap-Bootzeile ist ein bekannter grep-False-Positive auf `dsc`.)

### Plasma friert beim USB-C-Monitor-Anstecken ein (TTY läuft weiter) ✓ erlebt — nach Neustart weg
- **Symptom:** Beim Anstecken des USB-C-Monitors friert die grafische Session ein, bis das Kabel
  gezogen wird. Auf der TTY (`Strg+Alt+F3`) passiert **kein** Freeze — Kernel lebt.
- **Einordnung:** Trat gemeinsam mit einem vorangegangenen GPU-Hang auf
  (`i915 … GT1: hardware MCR steering semaphore timed out` + GuC-Reloads im dmesg; die
  `spd5118 … returns -6`-Meldungen sind Beifang des SPD-Sensors, nicht die Ursache). Nach einem
  **frischen Boot** war der Freeze nicht mehr reproduzierbar (Kernel-Log blieb sauber) — die GT
  hing mutmaßlich noch im kaputten Zustand der vorherigen Session. Seit dem Mainline-Wechsel
  nicht wieder aufgetreten.
- **Runbook, falls er wiederkommt:**
  ```bash
  # auf der TTY, Monitor angesteckt:
  for f in /sys/class/drm/card*/card*-*/status; do echo "$f: $(cat "$f")"; done
  journalctl --user -b | grep -iE "kwin|drm" | tail -40
  sudo dmesg | grep -iE "i915|drm" | tail -30
  ```
  Meldet `kwin_wayland` „Failed to open drm device" **ohne** i915-Fehler im Kernel-Log, ist der
  nächste Fix-Kandidat, den Compositor fest auf die iGPU zu pinnen (das display-lose
  nvidia-drm-Device der RTD3-dGPU — „Cannot find any crtc" — wird für KWin unsichtbar;
  PRIME-Offload nutzt den Render-Node und bleibt unberührt):
  ```nix
  environment.sessionVariables.KWIN_DRM_DEVICES = "/dev/dri/by-path/pci-0000:00:02.0-card";
  ```
  Hinweis: „Atomic modeset test failed! Keine Berechtigung" im KWin-Log ist **normal**, während
  man auf der TTY ist (KWin verliert beim VT-Wechsel den DRM-Master) — kein eigenständiges
  Fehlerbild.
