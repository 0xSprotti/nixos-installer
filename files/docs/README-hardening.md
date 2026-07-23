# README-hardening.md — Host-Härtung nach BSI SYS.2.3

**Was:** `modules/hardening.nix` setzt die Anforderungen des IT-Grundschutz-Bausteins
**SYS.2.3 Clients unter Linux und Unix** (Basis + Standard + erhöhter Schutzbedarf) auf den
**physischen Arbeits-Maschinen** der Flotte um. Die VMs (dev-vm, browser-vm)
importieren das Modul **nicht** — sie sind selbst die kompensierende Maßnahme: exponierte
Workloads (Browsing, Krypto, Entwicklung mit fremdem Code) laufen hinter der VM-Grenze,
nicht auf dem Host.

Dieses README ist eigenständig lesbar; die GSC-Erläuterungstexte (Abschnitt „Erläuterungen
je Anforderung") können 1:1 in das Grundschutz-Tool übernommen werden.

---

## Einbindung

1. `modules/hardening.nix` ins Repo (neben `desktop.nix`).
2. `hosts/<host>/usbguard-rules.conf` ins Repo (gepinnte Whitelist, s. u.).
3. In `hosts/<host>/configuration.nix`:

```nix
  imports = [
    # … bestehende Imports …
    ../../modules/hardening.nix
  ];

  # Gepinnte USBGuard-Whitelist dieses Hosts (Ausgabe von `usbguard generate-policy`).
  # Ohne diese Zeile bleibt USBGuard AUS (konservativer Default fuer neue Hosts).
  hardening.usbguard.rulesFile = ./usbguard-rules.conf;
```

4. `git add -A` (Flake sieht nur getrackte Dateien!), dann `sudo nixos-rebuild switch --flake .#<host>`.

**Weitere Hosts:** Modul importieren, aber **eigene** Regeldatei erzeugen — die Regeln tragen
gerätespezifische Hashes und Ports, die Liste eines anderen Geräts passt nie. Erstanlage als
Einzeiler: `bash usbguard-sync.sh --init` (erzeugt `hosts/<host>/usbguard-rules.conf`
aus dem Ist-Zustand; braucht keinen laufenden Daemon und holt die usbguard-CLI notfalls
flüchtig aus nixpkgs) — erst danach `rulesFile` setzen und rebuilden.

---

## Was das Modul konkret tut

| Bereich | Maßnahme |
|---|---|
| Wechsellaufwerke | udisks2 mountet Removables mit `noexec,nosuid,nodev` (deklarativ festgeschrieben) |
| AppArmor | LSM aktiv + nixpkgs-Profile; `killUnconfinedConfinables` bewusst aus |
| Platten-Überlauf | wöchentliche nix-GC (>14 d), `min-free` 2 GiB / `max-free` 8 GiB, journald ≤ 1 GiB |
| USBGuard | Whitelist aus dem Repo, alles andere geblockt; Notifier meldet Blocks am Desktop |
| Kernel | Härtungs-sysctls (kptr/dmesg-Restrict, BPF, yama-ptrace, kexec aus, fs-protected, SysRq=16) |
| Firewall | explizit an (Deterministik — war schon NixOS-Default) |

**Bewusste Abweichungen** (Kurzform; Begründung in den Erläuterungen unten):
noexec auf /home (A15) und `linuxPackages_hardened` (A18) werden **nicht** umgesetzt.

**Schwester-Modul:** Die Netz-Seite der Härtung — VM-Egress-Beschränkung, Inter-VM-Verbot,
VM→Host-Sperre — liefert `modules/vm-net-isolation.nix` (eigener Abschnitt
„VM-Netz-Isolation" weiter unten; Opt-in je Host, am Referenzgerät aktiv seit 2026-07-21).

---

## Verifikation nach dem ersten Switch

```bash
# AppArmor: Profile geladen, Modus je Profil
sudo aa-status | head -20

# udisks2: Stick einstecken, in Plasma mounten, dann:
findmnt /run/media/$USER/*        # OPTIONS muss noexec,nosuid,nodev enthalten

# USBGuard: Daemon aktiv, alle vorhandenen Geraete erlaubt (nichts geblockt = Liste passt)
systemctl status usbguard
usbguard list-devices             # alle Zeilen "allow"
usbguard list-devices --blocked   # muss LEER sein

# Notifier laeuft in der Session
systemctl --user status usbguard-notifier

# sysctls greifen (Stichprobe)
sysctl kernel.sysrq kernel.kptr_restrict kernel.unprivileged_bpf_disabled

# GC-Timer steht
systemctl list-timers | grep nix-gc
```

**Lockout-Hinweis:** Tastatur/Touchpad des Latitude hängen intern **nicht** am USB-Bus
(PS/2/I²C) — ein USBGuard-Fehlgriff sperrt die Eingabe also nicht aus. Internes Bluetooth
und die Webcam hängen dagegen sehr wohl am USB-Bus und stehen deshalb in der Regeldatei.
Fällt nach dem Aktivieren etwas aus (Bluetooth tot, Webcam weg): `usbguard list-devices
--blocked` zeigt den Kandidaten; Notfall-Rollback wie immer über
`sudo nixos-rebuild switch --rollback` oder das Bootmenü.

---

## USBGuard: Logging & Pflege-Workflow

**Wo landet was:**

- **Daemon-/Policy-Ereignisse:** `journalctl -u usbguard` (persistent, /var/log ist eigenes Subvolume)
- **Audit-Ereignisse** (allow/block je Gerät): USBGuard-Standard-Auditlog
  `/var/log/usbguard/usbguard-audit.log` (das NixOS-Modul exponiert das Backend nicht als
  Option; der Default bleibt)
- **Desktop:** usbguard-notifier zeigt jede allow/block-Entscheidung als Plasma-Benachrichtigung
- **Live:** `usbguard list-devices` / `usbguard list-devices --blocked` (dank
  `IPCAllowedGroups=[wheel]` ohne sudo)

**Neues Gerät erlauben (der einzige legitime Weg):**

1. Gerät anstecken → Notifier meldet Block.
2. `usbguard list-devices --blocked` → die Zeile des Geräts kopieren, führende Nummer und
   `block` entfernen, `allow` davorsetzen.
3. Zeile in `hosts/<host>/usbguard-rules.conf` eintragen (mit Kommentar wozu),
   `git add -A`, rebuild, committen.

**Nie** lokal `usbguard allow-device`/`append-rule` dauerhaft nutzen — das erzeugt Drift
zwischen System und Repo. (Ein temporäres `usbguard allow-device <nr>` für eine einzelne
Sitzung ist ok — es überlebt den Reboot nicht.)

**Sonderfall wandernde Dock-/Arbeitsplatz-Peripherie (Abwägung, 2026-07-22):** Für Geräte,
die an wechselnden Arbeitsplätzen/Ports auftauchen (Monitor-Hubs, Dock-Ethernet, geteilte
Tastatur/Maus), die kopierte Vollzeile **bewusst eindampfen** auf VID:PID — ohne `via-port`,
ohne `parent-hash`, ohne `name`; der Klarname wandert in den Kommentar:

```
# Arbeitsplatz-Dock (2026-07-22): bewusst OHNE via-port/parent-hash (wechselnde
# Arbeitsplaetze) und OHNE name-Matcher (exakter String-Match, fehleranfaellig).
allow id 0bda:5411   # USB2.1 Hub (Dock)
allow id 0bda:8153   # USB 10/100/1000 LAN (r8152, Dock)
allow id 17ef:6099   # Lenovo Traditional USB Keyboard
allow id 17ef:6019   # Lenovo USB Optical Mouse
```

Begründung: `via-port`/`parent-hash` binden die Regel an einen konkreten Port/Pfad — am
nächsten Arbeitsplatz greift sie nicht mehr und das Gerät ist wieder tot. Der `name`-Matcher
ist ein **exakter String-Vergleich**: ein einziger Tippfehler („Lenogo" statt „Lenovo", real
passiert) lässt die Regel still ins Leere laufen, das Gerät bleibt geblockt — schwer zu
diagnostizieren, weil die Regel „da" aussieht. VID:PID-only ist bei Allerwelts-Peripherie
der vertretbare Kompromiss: großzügiger als Hash-Pinning (jedes Gerät mit dieser VID:PID
wird akzeptiert), aber der Preis für Arbeitsplatz-Flexibilität; für **sicherheitskritische**
Einzelgeräte (z. B. Signier-Hardware) bleibt Hash-Pinning das Mittel der Wahl.
Diagnose-Signatur eines USBGuard-Blocks im Kernel-Log: `Device is not authorized for usage`
(dmesg) — Fehlerbild komplett in `troubleshooting.md` J.

**Erwartung WWAN-Nachrüstung (DW5932e):** Hängt der M.2-Slot am USB-Bus, erscheint das
Modem nach dem Einbau als geblocktes Gerät → Regel wie oben nachziehen, bevor die
ModemManager-Einrichtung beginnt.

---

## update-all.sh: Kernel-Reboot-Erkennung (SYS.2.3.A4)

NixOS aktiviert einen neuen Kernel erst beim Reboot — bis dahin läuft der alte weiter,
inklusive seiner bekannten Lücken. `update-all.sh` vergleicht deshalb nach der Aktivierung
`/run/booted-system/kernel` mit `/run/current-system/kernel` (Abschnitt 2b) und erinnert
bei Abweichung **prominent am Skriptende** an den Reboot. Bewusst kein Zwangs-Reboot
(konservativ; laufende Arbeit/VMs). Die Warnung steht auch im Session-Log.

---

## Werkzeug: systemd-analyze security (Bestandsaufnahme & Nachmessung)

Da AppArmor unter NixOS faktisch ohne Profile läuft (Befund s. A8), wird die
Rechtebeschränkung einzelner Dienste über **systemd-Unit-Härtung** erbracht. Bestandsaufnahme
und Erfolgskontrolle laufen über dieselben zwei Befehle. Sie sind bewusst generisch gehalten
und werden **1:1 für die Härtung von Kubernetes-Servern**
wiederverwendet — dort mit angepasster Kandidatenliste (z. B. `kubelet`, `containerd`,
`etcd`, `kube-apiserver`; Erwartung: die K8s-Kernkomponenten landen wie libvirtd in Korb 2,
die Gewinne liegen bei Neben- und Distro-Diensten).

```bash
# 1) Gesamtübersicht: alle Dienste mit Exposure-Score (0 = dicht, 10 = scheunentor-offen)
systemd-analyze security --no-pager

# 2) Für einzelne Kandidaten die Detail-Zusammenfassung (jeweils letzte Zeile = Score;
#    Liste je Host anpassen):
for u in libvirtd.service usbguard.service sshd.service dnsmasq.service \
         systemd-udevd.service NetworkManager.service accounts-daemon.service; do
  echo "== $u"; systemd-analyze security "$u" --no-pager 2>/dev/null | tail -2
done
```

Für die Detail-Analyse eines einzelnen Kandidaten (welche Direktive fehlt und was sie
bringen würde): `systemd-analyze security <unit> --no-pager` ohne `tail`.

**Lesart in drei Körben** (so wurde die Referenzgerät-Baseline vom 2026-07-20 bewertet):

1. **Schon gut (keine Aktion):** Dienste, deren NixOS-Module bereits gehärtete Units
   liefern — am Referenzgerät z. B. usbguard (2.8), polkit (1.2), logind (2.8),
   wpa_supplicant (1.7), timesyncd (2.1), bluetooth (3.5), journald (4.9).
   Positivbefund am Rande: auf den physischen Maschinen existiert kein sshd.service —
   die beste Härtung ist der Dienst, den es nicht gibt.
2. **Privilegiert by design (akzeptieren, begründet):** nix-daemon (baut als root),
   display-manager/SDDM, libvirtd + virtqemud (VM-Management braucht weite Rechte —
   tragende Architektur, nicht deren Schwachstelle), systemd-Infrastruktur (getty@,
   emergency/rescue, user@, ask-password). Hohe Scores hier sind erwartbar; blindes
   Sandboxen bricht Funktionalität. Ebenfalls akzeptiert (sandboxen schlecht, ohne
   Funktion zu riskieren): udisks2 (Wechselmedien-Mounts), NetworkManager-dispatcher
   (Dispatcher-Skripte). ModemManager wird zusammen mit dem WWAN-Einbau angegangen.
3. **Echte Kandidaten:** ungenutzte privilegierte Dienste (→ maskieren = Angriffsfläche
   entfernen) und kleine root-Daemons mit klarem Aufgabenprofil (→ sandboxen).

**Baseline Referenzgerät (2026-07-20, vor der Dienst-Härtung)** — Auszug der relevanten Werte:
virtlxcd/virtvboxd/virtxend je 9.6 UNSAFE (Hypervisor-Daemons für LXC/VirtualBox/Xen —
hier ungenutzt, es fährt ausschließlich QEMU/KVM), acpid 9.6 UNSAFE (kam mit dem
NVIDIA-Stack), virtlogd/virtlockd je 9.6 UNSAFE.

**Umgesetzte Maßnahmen (modules/hardening.nix, Baustein „A8/A17-Ergänzung"):**
Maskierung von virtlxcd/virtvboxd/virtxend samt aller Sockets (drei UNSAFE-Einträge
entfallen ersatzlos; virtqemud bleibt unangetastet) und konservatives Sandboxing für
acpid (read-only-Dateisystem, nur AF_UNIX+AF_NETLINK, NoNewPrivileges — die
ACPI-Handler-Skripte laufen unverändert; nachgemessen 2026-07-20: 9.6 → 5.7).
**Stufe 2 (umgesetzt 2026-07-21):** virtlogd, virtlockd und virtsecretd sind gesandboxt —
gemeinsamer Satz `virtHelperSandbox` in `modules/hardening.nix`, Guard `mkIf
libvirtd.enable` (auf Hosts ohne libvirt: No-op statt leerer Unit-Hüllen). Bewusst
**schärfer als acpid**, und zwar genau aus dem Grund, aus dem acpid weich blieb: die drei
exec'en nichts, sprechen ausschließlich Unix-Sockets und haben ein exakt bekanntes
Schreibset — deshalb `ProtectSystem=strict` mit engen `ReadWritePaths` (virtlogd:
`/var/log/libvirt` — er öffnet die Gast-Logs und reicht die FDs an qemu durch;
virtlockd/virtsecretd: `/var/lib/libvirt` — deckt eine spätere `lock_manager="lockd"`-
Aktivierung ebenso ab wie Secrets, die auf NixOS unter `/var/lib/libvirt` liegen;
`/run/libvirt` für alle drei), dazu `PrivateNetwork` und nur `AF_UNIX`. Die zunächst
vertagten `CapabilityBoundingSet`/`SystemCallFilter` sind für die drei Helfer inzwischen
nachgezogen (→ Stufe 3 unten). virtsecretd bleibt wie geplant **unmaskiert** (anders als
LXC/VBox/Xen): virtqemud weckt ihn bei Bedarf per Socket — eine Maskierung würde künftige
Features (z. B. LUKS-verschlüsselte Gast-Disks) leise brechen. Die ursprünglich angesetzte
Beobachtungsphase wurde bewusst **vorgezogen** (Kurskorrektur, kein Versehen): die drei
Helfer sind vom acpid-Muster funktional unabhängig, virtlockd und virtsecretd ohne aktive
Nutzung idle, und die Funktionsprobe deckt den einzig aktiven virtlogd unmittelbar ab.
**Ausrollen:** der switch restartet virtlogd bewusst **nicht** (NixOS-Modul:
`restartIfChanged=false` — schützt die Log-FDs laufender Gäste; empirisch 2026-07-21:
„NOT restarting … virtlogd.service" in der Aktivierungs-Ausgabe). Die Sandbox greift erst
nach **manuellem Neustart bei gestoppten VMs**: `sudo systemctl restart virtlogd`
(virtlockd/virtsecretd sind normalerweise inactive und starten beim nächsten Socket-Accept
bereits gesandboxt). **Messfalle:** `systemd-analyze security` bewertet die *geladene*
Unit — der Score sieht schon vor dem Neustart gut aus, der laufende Prozess ist aber noch
der alte; Nachmessung und Funktionsprobe zählen erst **nach** dem Neustart. **virtqemud bleibt bewusst ungehärtet** (dokumentierte Abweichung,
kein Vergessen): er spawnt qemu mit breitem Device-/cgroup-/Namespace-Bedarf (Korb 2); die
Rechtebegrenzung des QEMU-Pfads erbringen VM-Grenze + nftables-Isolation (→ A17).
**Nachgemessen am Referenzgerät 2026-07-21** (nach dem manuellen virtlogd-Neustart):
virtlogd 9.6 UNSAFE → **4.8 OK**, virtlockd 9.6 UNSAFE → **4.8 OK**, virtsecretd
9.6 UNSAFE (Baseline nachgeholt) → **4.8 OK**. Funktionsprobe fehlerfrei: der
dev-vm-Boot schrieb frische Zeilen nach `/var/log/libvirt/qemu/dev-vm.log` — mit
Zeitstempel *nach* dem Neustart, also nachweislich über die gesandboxte Instanz —, SSH in
den Gast ok, Journal der drei Units ohne Denials, `check-libvirt.sh` grün. Der damals
verbleibende Score-Sockel (root-User, CapabilityBoundingSet, SystemCallFilter) war exakt
der Stufe-3-Anteil — für die drei Helfer noch am selben Tag nachgezogen (s. u.).

**Stufe 3 (umgesetzt 2026-07-21 — nur die drei virt-Helfer; acpid s. u.):** Der
gemeinsame Satz `virtHelperSandbox` erhält `CapabilityBoundingSet = ""` (kompletter
Drop — die Helfer brauchen als root mit ausschließlich root-eigenen Dateien keine einzige
Capability; Eigentümer-Zugriff läuft ohne `DAC_OVERRIDE`) und
`SystemCallFilter = "@system-service"` (das erprobte systemd-Standardset; deckt
`sendmsg`/SCM_RIGHTS fürs FD-Durchreichen an qemu und `execve` für den virtlogd-Re-Exec
ab — handgeschnitzte Syscall-Listen bewusst nicht: Pflegeaufwand ohne belastbaren
Mehrwert). Verletzungen enden per Default in einem **sichtbaren SIGSYS im Journal** —
bewusst laut statt stiller Degradation. Ausrollen wie bei Stufe 2 gelernt: switch
restartet virtlogd nicht — manueller `sudo systemctl restart virtlogd` bei gestoppten
VMs, erst dann zählen Messung und Funktionsprobe.
**acpid-Stufe-3 (umgesetzt 2026-07-23 — Kurskorrektur vom 2026-07-22, dokumentiert):** Das tags zuvor
gesetzte Abnahmekriterium „zwei Wochen Normalbetrieb" wurde nicht ausgesessen, sondern
durch **vollständige Aufzählung ersetzt**: die empirische Handler-Inventur auf dem Referenzgerät
(confdir plus alle `action=`-Skripte im Wortlaut) ergab, dass `acEvent.sh`,
`lidEvent.sh` und `powerEvent.sh` **leere Bash-Skripte** sind (Shebang, sonst nichts —
im Repo ist kein `*EventCommands` konfiguriert; das Power-Management macht
logind/Plasma). Damit ist das Handler-Verhalten vollständig umrissen (Event → Bash
spawnen → Exit), der „über Wochen verteilte Randfall" hat exakt denselben Codepfad wie
der Sofort-Test — dieselbe Logik, die schon die Helfer-Beschleunigung trug. acpid erhält
dieselben zwei Knöpfe (`CapabilityBoundingSet = ""`, `SystemCallFilter =
"@system-service"`); `ProtectSystem` bleibt bewusst bei `full` (acpid legt Socket und
PID-Datei selbst unter `/run` an — strict brächte ReadWritePaths-Pflege bei geringem
Mehrwert). **Kritischer Verifikations-Check ist ein Positiv-Beweis, nicht die
Fehler-Suche:** bräuchte der Netlink-Multicast-Join für ACPI-Events wider Erwarten eine
Capability, gäbe es kein SIGSYS, sondern stille Event-Taubheit. **Verfahrens-Korrektur
(Lektion 2026-07-23):** der zunächst angesetzte Journal-Check kann den Empfang prinzipiell
nicht belegen — acpid loggt empfangene Events nicht (`waiting for events: event logging is
off`); ein Journal-Grep prüft nur Fehler-Abwesenheit. Der Beweis läuft über `acpi_listen`
(liest live am acpid-Socket mit; Binary neben dem `acpid` der Unit):

```bash
ACPID_BIN=$(systemctl show -p ExecStart acpid | grep -o '/nix/store/[^ ;]*/bin/acpid' | head -1)
sudo timeout 20 "${ACPID_BIN%acpid}acpi_listen"   # währenddessen Netzteil ziehen/stecken
```

(acpid restartet beim Switch normal — die virtlogd-Neustart-Falle gilt hier nicht.)
**Nachgemessen am Referenzgerät 2026-07-23 (acpid-Stufe-3):** 5.7 MEDIUM → **2.3 OK**.
Positiv-Beweis per `acpi_listen`: AC-Adapter-Events **beider Richtungen** samt der
normalen Battery-/Processor-Kaskaden erschienen live durch den gesandboxten Daemon —
Netlink-Empfang und Socket-Weitergabe unter komplettem Caps-Drop belegt. Dazu ein voller
Suspend/Resume-Zyklus, Journal ohne SIGSYS/seccomp, Unit aktiv. Power-Button bewusst
nicht Teil der Batterie (geht an logind, kein acpid-Beweis).*
**Nachgemessen am Referenzgerät 2026-07-21 (Stufe 3, nach manuellem virtlogd-Neustart):**
virtlogd 4.8 → **1.4 OK**, virtlockd 4.8 → **1.4 OK**, virtsecretd 4.8 → **1.4 OK**.
Funktionsprobe gegen die gesandboxte Instanz fehlerfrei: frischer dev-vm-Startzyklus
schreibt ins qemu-Log (Verbindung annehmen → Logdatei öffnen → FD an qemu durchreichen →
schreiben — der volle Arbeitszyklus unter Caps-Drop + Syscall-Filter), SSH in den Gast ok,
Journal ohne SIGSYS/seccomp-Einträge, Unit aktiv. **Ausroll-Lektion (2026-07-21):** die
Funktionsprobe zählt nur mit einem Gast-Start **nach** dem virtlogd-Neustart — lief eine
VM durch den Neustart hindurch, hängt ihr Logging noch an der alten Instanz (die Session
läuft harmlos weiter, taugt aber nicht als Beweis; vor dem Neustart deshalb wirklich
`virsh list --state-running` prüfen und laufende Gäste stoppen).
**Hoher Score, aber praktisch irrelevant (Akzeptanz mit Begründung):** libvirt-guests,
reload-systemd-vconsole-setup und systemd-rfkill sind Oneshots bzw. Millisekunden-Kurzläufer
(Boot/Shutdown- bzw. Event-getrieben) — Sandboxing dort wäre Score-Kosmetik ohne
Sicherheitsgewinn. Ebenso bleibt user@1000 (die eigene Benutzer-Session) naturgemäß breit.

**Nachmessung** nach jedem Härtungs-Change: Befehl 1 erneut ausführen und mit der
Baseline vergleichen; zusätzlich Funktionsprobe der betroffenen Dienste (hier: beide VMs
einmal starten/stoppen, ACPI-Handler per Netzteil-Ziehen/-Stecken auslösen und
`journalctl -u acpid` auf Fehler prüfen).

---

## VM-Netz-Isolation (`modules/vm-net-isolation.nix`)

**Was:** Host-seitige nftables-Regeln, die die VM-Netze auf ihre Aufgabe einschnüren
(umgesetzt 2026-07-21; Design-Entscheidungen: Kopf von `modules/vm-net-isolation.nix`). Vorher routete das
libvirt-NAT beide VMs ungefiltert ins LAN, an Host-Dienste und zueinander — die
NixOS-Firewall filtert nur *eingehenden Host*-Verkehr. Policy jetzt:

| Verkehr | dev-vm | browser-vm |
|---|---|---|
| → Internet | nur tcp **22** (git-SSH) + **443** | nur tcp **80/443** + udp **443** (QUIC) |
| → LAN / private Netze (RFC 1918 + Link-Local, v4 **und** v6) | ✗ | ✗ |
| → andere VM | ✗ (explizite Regel vor allen Ausnahmen) | ✗ |
| → Host | nur DNS (53) + DHCP (67/udp) zur Bridge-`.1` | dito |
| Host → VM (ssh, waypipe, SPICE, ssh-Debug) | ✓ unverändert (Host-Output/localhost; Antworten via `ct state established`) | ✓ |

**Mechanik:** Eigene Tabelle `inet vm-isolation` **neben** libvirts Regeln — nftables
wertet alle Tabellen aus, ein Drop gewinnt tabellenübergreifend; libvirts NAT/DHCP bleibt
unangetastet (kein Hook-Skript, kein Patchen; `flushRuleset` festgeschrieben `false`).
Die Regeln matchen per Interface-Name auf den Bridges — die Namen kommen aus
`host.devVm.bridge` / `host.browserVm.bridge` (Spiegel: `BRIDGE_NAME` in den
`deploy-*-vm.sh`). Kehrseite derselben Mechanik (empirisch 2026-07-21): `nixos-fw`
droppte anfangs die DNS/DHCP-Anfragen der VMs, weil libvirts Accepts in einer anderen
Tabelle liegen — das Modul gibt deshalb 53 (udp/tcp) + 67/udp interface-gebunden **nur**
auf den VM-Bridges in der NixOS-Firewall frei (`troubleshooting.md` §F).

### Einbindung (am Referenzgerät aktiv; weitere Hosts analog)

```nix
  imports = [ … ../../modules/vm-net-isolation.nix ];

  networking.nftables.enable = true;     # BEWUSSTER Backend-Wechsel der Host-Firewall
  hardening.vmNetIsolation.enable = true;
```

Das Modul erzwingt das nftables-Backend per Assertion, statt es still zu setzen —
`networking.firewall` läuft funktional unverändert weiter, nur das Backend wechselt.
Konservativer Default: ohne die `enable`-Zeile bleibt alles aus.

### Ausnahme-Workflow (der einzige legitime Weg)

Zusätzliche Egress-Ports sind Options-Overrides **im Host-Ordner, mit Kommentar wozu** —
nie stille Edits im Modul:

```nix
  # kubectl -> <cluster-api> (dokumentierte Ausnahme, 2026-XX-XX):
  hardening.vmNetIsolation.devVm.allowedTcpPorts = [ 22 443 6443 ];
```

LAN-Ziele bleiben davon unberührt gesperrt (der RFC-1918-Drop greift **vor** den
Port-Accepts); eine LAN-Ausnahme wäre ein bewusster Modul-Eingriff mit eigener
Begründung. **Bewusst nicht freigegeben:** NTP 123/udp (Gast-Uhr kommt via kvm-clock/RTC
vom Host; timesyncd-Meldungen im Gast sind kosmetisch — troubleshooting.md §F) und
ICMP-Egress (Internet-Positivtest läuft über `curl`, nicht `ping`).

### Erreichbarkeits-Matrix (Soll) — nach jedem Switch mit Regel-Änderung

Messung per SSH vom Host (`ssh dev@192.168.243.2` bzw. `ssh browse@192.168.244.2`).
**Vorher-Messung 2026-07-21 (ohne Modul): alle Zeilen erreichbar** — das dokumentiert
die geschlossene Lücke.

| Probe (aus der VM) | dev-vm | browser-vm |
|---|---|---|
| `getent hosts example.com` (DNS via Bridge-`.1`) | OK | OK |
| `ping -c1 -W2 <Bridge-.1>` | FAIL | FAIL |
| `ping -c1 -W2 <lan-gateway>` (Router-IP) | FAIL | FAIL |
| `curl -m5 https://<lan-gateway> -k` (LAN per TCP) | FAIL | FAIL |
| `ping -c1 -W2 <andere VM>` (243.2 ↔ 244.2) | FAIL | FAIL |
| `curl -m5 https://example.com` | OK | OK |
| `curl -m5 http://neverssl.com` (Port 80) | FAIL *(80 nicht im dev-Set)* | OK |
| `ssh -T git@github.com` (Port 22) | OK *(„successfully authenticated")* | — |
| `ping -c1 -W2 9.9.9.9` (ICMP-Egress) | FAIL *(gewollt)* | FAIL *(gewollt)* |

Negativ-Proben erhöhen sichtbar die Drop-Counter — das ist die zweite Bestätigung:

```bash
sudo nft list table inet vm-isolation     # Regel-Inventur + counter packets/bytes
```

### GSC-Nachweis

Die Ausgabe von `sudo nft list table inet vm-isolation` ist die **Regel-Inventur des
Hosts** (Ziel d des Bauschritts) und wird zusammen mit der ausgefüllten Matrix im
Grundschutz-Tool abgelegt; sie stützt die A17-Argumentation (s. u.) mit technisch
erzwungener statt nur architektonisch vorbereiteter Netztrennung.

### Rollback

`hardening.vmNetIsolation.enable = false;` + rebuild (das nftables-Backend kann
unabhängig davon aktiv bleiben) — oder im systemd-boot-Menü die vorherige Generation.

---

## Erläuterungen je Anforderung (für den Grundschutzcheck)

Texte in der Ich-Form der Institution, direkt übernehmbar; Status-Vorschlag in Klammern.

**A1 — Authentisierung von Administratoren und Benutzern (B)** *(Erfüllt)*
Kein root-Login im Normalbetrieb; administrative Tätigkeiten laufen über sudo mit
Passwortabfrage, Protokollierung über das systemd-Journal. Die Maschinen sind
Ein-Personen-Arbeitsplätze; ein technisches Verbot paralleler Logins Dritter ist damit
gegenstandslos (SOLLTE-Anteil, dokumentierte Bewertung). In den Wegwerf-VMs ist sudo
passwortlos — dokumentierte Abwägung: die VM ist die Sicherheitsgrenze, der Host der
Vertrauensanker; die VMs sind ephemer (transient Overlay/tmpfs).

**A2 — Auswahl einer geeigneten Distribution (B)** *(Erfüllt)*
NixOS (aktuell 26.05) mit laufendem Upstream-Support. Sämtliche Software kommt aus den
offiziellen nixpkgs-Quellen und ist deklarativ mit Version und Hash im Flake gepinnt;
Drittquellen werden nicht verwendet. Das System wird nicht selbst kompiliert, sondern aus
dem offiziellen Binary-Cache bezogen (Ausnahmen sind reproduzierbar im Repo dokumentiert).

**A4 — Kernel-Aktualisierungen (B)** *(Erfüllt nach Umsetzung)*
Updates laufen über ein versioniertes Update-Verfahren (update-all.sh). Das Verfahren
erkennt Kernel-Aktualisierungen (Vergleich gebooteter/konfigurierter Kernel) und fordert
am Ende des Laufs sichtbar zum zeitnahen Reboot auf; die Aufforderung wird im Session-Log
festgehalten. Kernel-Live-Patching ist auf Arbeitsplatz-Clients nicht erforderlich, da
Reboots kurzfristig möglich sind.

**A5 — Sichere Installation von Software-Paketen (B)** *(Erfüllt)*
Software-Builds laufen unter Nix grundsätzlich in einer Sandbox unter unprivilegierten
Build-Benutzern (nixbld) und schreiben ausschließlich in den Nix-Store, nie unkontrolliert
ins Wurzeldateisystem. Alle Build-Parameter sind deklarativ im Flake dokumentiert; jeder
Build ist jederzeit reproduzierbar (bit-für-bit nachvollziehbare Derivations).

**A6 — Kein automatisches Einbinden von Wechsellaufwerken (S)** *(Erfüllt)*
Wechseldatenträger werden nicht automatisch eingebunden (Plasma zeigt nur eine
Benachrichtigung; das Einbinden ist eine manuelle Aktion). Deklarativ festgeschrieben ist
zusätzlich, dass udisks2 Wechseldatenträger stets mit `noexec,nosuid,nodev` mountet —
Dateien auf Wechselmedien sind damit nie ausführbar.

**A7 — Restriktive Rechtevergabe auf Dateien und Verzeichnisse (S)** *(Erfüllt)*
Auf world-writable Verzeichnissen (/tmp, /var/tmp) ist das Sticky Bit gesetzt
(Systemstandard); ergänzend sind die Kernel-Schutzmechanismen für Symlinks, Hardlinks,
FIFOs und reguläre Dateien in solchen Verzeichnissen aktiviert (fs.protected_*). Dienste
laufen unter systemd mit eigenen Dienstkonten.

**A8 — Techniken zur Rechtebeschränkung von Anwendungen (S)** *(Erfüllt über systemd-Härtung; AppArmor formal)*
AppArmor ist als LSM aktiv (verifiziert 2026-07-20: `apparmor` in der `lsm=`-Bootliste,
securityfs voll ausgeprägt, `aa-enabled` = Yes). Empirischer Befund am selben Tag: der
geladene **Profilsatz ist leer** (0 Profile, kein Prozess confined) — die
Upstream-Profilsammlung adressiert FHS-Pfade und greift auf NixOS-Store-Pfaden nicht; das
LSM ist damit aktiv, aber ohne eigene Wirkung. (Nebenbefund: `aa-status` scheitert am
leeren Profilsatz mit „Failed to get profiles: 2" — Tooling-Problem, kein
Sicherheitsproblem; s. troubleshooting.md, Abschnitt J.) Das LSM bleibt bewusst aktiv:
kostenneutral, und Pakete mit eigenen Profilen können andocken. Die Rechtebeschränkung
wird stattdessen NixOS-nativ erbracht, in drei Schichten: (1) **Maskierung** ungenutzter
privilegierter Dienste (virtlxcd/virtvboxd/virtxend samt Sockets — Angriffsfläche
entfernt statt gesandboxt), (2) **systemd-Sandboxing** verbleibender Kandidaten (acpid; seit
2026-07-21 auch virtlogd/virtlockd/virtsecretd — virtqemud bleibt als dokumentierte
Abweichung breit, Korb 2), (3) als stärkste Schicht die **VM-Isolation** sämtlicher
exponierter Workloads (browser-vm mit transient Overlay + tmpfs-Home, dev-vm) — eine
härtere Isolationsgrenze als jedes LSM-Profil. Mess- und Nachweisverfahren: Abschnitt
„systemd-analyze security".

**A9 — Sichere Verwendung von Passwörtern auf der Kommandozeile (S)** *(Erfüllt)*
Skripte des Repos übergeben Passwörter nie als Programmparameter (Beispiel install.sh:
verdeckte Eingabe per `read -rs`, Übergabe an mkpasswd über stdin). Secrets liegen
ausschließlich als Hashes unter /persist/secrets.

**A11 — Verhinderung der Überlastung der lokalen Festplatte (S)** *(Erfüllt)*
Betriebssystem, /home, /nix, /persist und /var/log liegen auf getrennten
btrfs-Subvolumes. Der realistische Füll-Kandidat /nix ist dreifach gedeckelt: wöchentliche
automatische Garbage Collection (Generationen älter 14 Tage), automatisches Freiräumen
während Builds (min-free 2 GiB / max-free 8 GiB) und journald-Begrenzung auf 1 GiB.
Klassische Benutzer-Quotas sind auf einem Ein-Personen-System ohne Mehrwert
(dokumentierte Bewertung).

**A12 — Sicherer Einsatz von Appliances (S)** *(Entbehrlich)*
Es werden keine unixbasierten Appliances als Clients eingesetzt.

**A14 — Absicherung gegen Nutzung unbefugter Peripheriegeräte (H)** *(Erfüllt)*
USBGuard mit Default-Block: nur Geräte auf der Whitelist werden autorisiert;
Kernel-Treiber-Bindung erfolgt erst nach Autorisierung. Die Whitelist ist die im
Git-Repository versionierte, pro Host gepinnte Regeldatei (usbguard-rules.conf) — damit
wörtlich „zentral verwaltet", jede Änderung ist ein nachvollziehbarer Commit. Blockierte
Geräte werden am Desktop gemeldet (usbguard-notifier) und auditiert.

**A15 — Zusätzlicher Schutz vor der Ausführung unerwünschter Dateien (H)**
*(Dokumentierte Abweichung / Risikoübernahme)*
noexec auf /home wird nicht umgesetzt: der Editor (Zed) lädt Language-Server nach
~/.local und führt sie aus; noexec würde den Arbeitsplatz funktional brechen.
Kompensation: Entwicklung mit fremdem Code findet in der dev-VM statt, nicht auf dem
Host; Wechselmedien sind bereits noexec (A6); world-writable Systempfade sind über
Sticky Bit + fs.protected_* gehärtet (A7). Restrisiko wird getragen.

**A17 — Zusätzliche Verhinderung der Ausbreitung bei Ausnutzung von Schwachstellen (H)**
*(Erfüllt über Architektur + technisch erzwungene Netztrennung)*
Auf den Hosts laufen keine exponierten Netzdienste (Firewall aktiv, kein sshd auf den
physischen Maschinen); die Rechtebeschränkung auf dem Host erfolgt über
systemd-Unit-Härtung und Dienst-Maskierung (A8). Exponierte Anwendungen laufen in VMs
mit dediziertem Bridge-Netz je VM, dessen Isolation seit 2026-07-21 per nftables
**technisch erzwungen** ist (`modules/vm-net-isolation.nix`): die browser-VM erreicht
ausschließlich das Internet (80/443 + QUIC), die dev-VM nur 22/443, Verkehr zwischen den
VMs sowie in LAN und zu Host-Diensten ist verworfen (einzige Host-Ausnahme: DNS/DHCP der
jeweiligen Bridge). Eine kompromittierte VM kann sich damit weder lateral zur anderen VM
noch ins lokale Netz noch auf den Host ausbreiten — die Ausbreitungs-Begrenzung erfolgt
an der VM-Grenze statt über per-Prozess-seccomp-Profile. Nachweis: Regel-Inventur
(`nft list table inet vm-isolation`) und Erreichbarkeits-Matrix, beide im Abschnitt
„VM-Netz-Isolation" dieses Dokuments.

**A18 — Zusätzlicher Schutz des Kernels (H)** *(Erfüllt mit Begründung der Mittelwahl)*
Die vom Baustein beispielhaft genannten Härtungs-Patches (grsecurity/PaX) sind seit 2017
nicht mehr frei verfügbar. Umgesetzt ist stattdessen eine Kernel-Härtung über sysctl:
kptr_restrict=2, dmesg_restrict=1, unprivileged_bpf_disabled=1, bpf_jit_harden=2,
yama.ptrace_scope=1, kexec_load_disabled=1, suid_dumpable=0, fs.protected_*. Auf den
gesondert gehärteten Kernel (linuxPackages_hardened) wird verzichtet, da er mit dem
Virtualisierungs-Fundament (libvirt/KVM/VFIO — tragende Sicherheitsarchitektur dieses
Verbunds) kollidieren kann; die VM-Isolation wiegt schwerer als der Zusatzgewinn des
gehärteten Kernels (dokumentierte Abwägung).
Verträglichkeitsnotiz (2026-07-16): `yama.ptrace_scope=1` ist mit dem nativen Steam/Proton
am Referenzgerät verifiziert kompatibel; nur exotisches Spiele-Tooling (Debugger/Injektoren)
wäre bei Einzelfällen der erste Verdächtige.

**A19 — Festplatten- oder Dateiverschlüsselung (H)** *(Erfüllt)*
Vollverschlüsselung aller internen Datenträger mit LUKS2 (deklarativ via disko,
reproduzierbar im Repo). Der Schlüssel (Passphrase) ist nicht auf dem System gespeichert.
Abweichung vom SOLLTE-Detail „AEAD-Verfahren": LUKS2 nutzt standardmäßig AES-XTS ohne
Authentisierung; die Integritätsanforderung wird über die übrigen Maßnahmen (physischer
Schutz des Geräts, Secure Boot-Kette des Bootloaders auf der unverschlüsselten ESP als
bekanntes Restrisiko) bewertet und getragen.

**A20 — Abschaltung kritischer SysRq-Funktionen (H)** *(Erfüllt)*
kernel.sysrq=16: ausschließlich die unkritische Sync-Funktion ist zugelassen, alle
kritischen SysRq-Funktionen (Prozess-Kill, Reboot, Speicher-Dump etc.) sind für Benutzer
deaktiviert. Der Wert ist deklarativ festgeschrieben.

**Ergänzend — Schutz vor Schadprogrammen (OPS.1.1.4, auf Nachfrage):**
Auf einen signaturbasierten Virenscanner in der browser-VM wird bewusst verzichtet
(dokumentierte Bewertung): die VM ist vollständig ephemer (transient Root-Overlay,
tmpfs-Home) — jede Kompromittierung endet mit dem Herunterfahren; es existiert kein
Datenpfad von der VM zum Host, an dem ein On-Access-Scanner eine Übergabe prüfen könnte.
Die Wegwerf-Architektur ist die wirksamere Kontrolle.

