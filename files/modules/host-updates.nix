# modules/host-updates.nix
# ─────────────────────────────────────────────────────────────────────────────
# Generische Host-Wartung: erinnert an neue nixpkgs-Staende, bietet einen
# Ein-Klick-Weg, alles zu aktualisieren, und bringt fwupd fuer Firmware/BIOS mit.
# Haengt NUR am Repo unter ~/nixos-config (kein dev-VM- oder Hardware-Bezug)
# -> jeder Host kann es einzeln importieren.
#
# Drei abgestimmte Teile: Erinnerung (stuendlicher User-Timer; Snooze = Timer stoppen
# + transienter systemd-Wecker, KEIN State-File) -> Knopf (Desktop-Icon) -> ein Befehl
# (update-all.sh: Flake bumpen + Host + alle VMs + Firmware).
# Bewusst KEIN system.autoUpgrade: nichts aktualisiert unbeaufsichtigt.
{ lib, pkgs, ... }:
let
  # GUI-Launcher fuer Updates: oeffnet konsole und laesst update-all.sh laufen (Fenster bleibt offen).
  # Wird vom Update-Icon UND von der "Jetzt aktualisieren"-Benachrichtigung aufgerufen.
  nixos-update-gui = pkgs.writeShellScriptBin "nixos-update-gui" ''
    exec konsole -e bash -lc 'cd "$HOME/nixos-config" && bash update-all.sh; echo; read -rp "Fertig — Enter schliesst das Fenster. "'
  '';

  # Hintergrund-Check: vergleicht den gepinnten nixpkgs-Stand (flake.lock) mit dem Upstream-Branch.
  # Gibt es Neues -> Desktop-Benachrichtigung mit Snooze-Knoepfen. Snooze laeuft rein ueber
  # systemd (Stunden-Timer stoppen + transienter --on-calendar-Wecker, kein State-File);
  # ein aktiver Snooze ist via 'systemctl --user list-timers' sichtbar.
  # Vom systemd-User-Timer (stuendlich) ausgeloest. Tut nichts ohne grafische Sitzung.
  nixos-update-check = pkgs.writeShellScript "nixos-update-check" ''
    set -uo pipefail
    # pkgs.systemd: systemd-run/systemctl fuer den Snooze-Wecker garantiert im PATH.
    export PATH=${lib.makeBinPath [ pkgs.git pkgs.jq pkgs.libnotify pkgs.coreutils pkgs.systemd ]}:/run/current-system/sw/bin:$PATH

    REPO="$HOME/nixos-config"
    LOCK="$REPO/flake.lock"
    [ -f "$LOCK" ] || exit 0
    # (Kein Snooze-Gate mehr: waehrend eines Snooze ist der Stunden-Timer selbst gestoppt,
    #  dieser Check laeuft dann schlicht nicht. Sichten/Aufheben: troubleshooting.md, D.)

    # Gepinnten nixpkgs-Branch aus flake.lock lesen (robust ueber den root-Input). Der Branch
    # aendert sich durch einen Bump nicht -> bleibt die richtige Quelle fuer den ls-remote unten.
    node=$(jq -r '.nodes.root.inputs.nixpkgs // "nixpkgs"' "$LOCK")
    ref=$(jq -r --arg n "$node" '.nodes[$n].original.ref // "nixos-26.05"' "$LOCK")

    # Vergleichsbasis ist der Stand des LAUFENDEN Systems (nixos-version), NICHT flake.lock auf der
    # Platte: ein halbfertiger 'nix flake update' (flake.lock gebumpt, aber Host noch nicht gebaut)
    # wuerde sonst faelschlich als "kein Update" gewertet -> die Erinnerung verstummt dauerhaft.
    # nixpkgsRevision = die nixpkgs-Revision, mit der der laufende Host gebaut wurde.
    localrev=$(nixos-version --json 2>/dev/null | jq -r '.nixpkgsRevision // ""')
    # Fallback nur, wenn nixos-version keine Revision liefert (z. B. dirty build): flake.lock auf
    # der Platte. Den verwaisten-Bump-Fall faengt dann update-all.sh per Rollback ab (Kombi-Loesung).
    [ -n "$localrev" ] || localrev=$(jq -r --arg n "$node" '.nodes[$n].locked.rev // ""' "$LOCK")
    [ -n "$localrev" ] || exit 0

    # Upstream-HEAD des Branches (leichtgewichtig; offline/Fehler/Timeout -> still raus).
    upstream=$(timeout 20 git ls-remote https://github.com/NixOS/nixpkgs "refs/heads/$ref" 2>/dev/null | cut -f1)
    [ -n "$upstream" ] || exit 0
    [ "$localrev" = "$upstream" ] && exit 0

    # Es gibt Neues -> benachrichtigen und bis zu 1 h auf eine Aktion warten.
    rc=0
    choice=$(timeout 3600 notify-send \
      --app-name="NixOS" --icon=system-software-update --urgency=normal --expire-time=0 \
      --action=now="Jetzt aktualisieren" \
      --action=1h="In 1 Stunde" \
      --action=8h="In 8 Stunden" \
      --action=1d="Morgen" \
      "NixOS-Updates verfuegbar" \
      "Der nixpkgs-Kanal ($ref) ist weitergewandert. Jetzt aktualisieren oder spaeter erinnern lassen." \
      2>/dev/null) || rc=$?

    # rc=124 -> Timeout: niemand hat reagiert -> NICHTS tun; der Stunden-Timer laeuft weiter
    #   und erinnert beim naechsten Takt erneut. (Frueher galt Timeout als "morgen" — zusammen
    #   mit der dann toten Zombie-Benachrichtigung, deren Klicks ins Leere laufen, die Ursache
    #   fuer tagelanges Schweigen.)
    # rc weder 0 noch 124 -> notify-send-Fehler (kein Daemon/keine GUI) -> ebenfalls nichts
    #   tun; der naechste Stundenlauf versucht es neu.
    [ "$rc" -eq 0 ] || exit 0

    # Snooze rein ueber systemd — fuer JEDE Dauer (1 h / 8 h / morgen) derselbe Weg, nur mit
    # anderer Weckzeit. Reihenfolge ist Wecker-FIRST: erst den transienten Wecker setzen,
    # ERST WENN das geklappt hat, den Stunden-Timer stoppen. Schlaegt systemd-run fehl,
    # bleibt der Timer an -> die Erinnerung kommt schlimmstenfalls zu frueh, nie gar nicht.
    # --on-calendar statt --on-active: die monotone Uhr steht im Suspend still — ein "+8 h"-
    #   Wecker wuerde um jede Deckel-zu-Zeit verrutschen. Kalender-Timer feuern nach dem
    #   Aufwachen sofort nach, wenn die Weckzeit im Schlaf verstrichen ist.
    # Reboot/Logout raeumt transiente User-Units ab; der Stunden-Timer startet beim naechsten
    #   Login via timers.target von selbst -> Snooze vergessen heisst nur "Erinnerung kommt
    #   zu frueh", nie "kommt nicht mehr" (gutartige Degradation).
    snooze() {
      wake=$(date -d "$1" '+%Y-%m-%d %H:%M:%S') || return 0
      systemctl --user stop nixos-update-snooze.timer 2>/dev/null || true   # Doppel-Snooze raeumen
      systemctl --user reset-failed nixos-update-snooze.service 2>/dev/null || true
      if systemd-run --user --collect --unit=nixos-update-snooze --on-calendar="$wake" \
           systemctl --user start nixos-update-check.timer nixos-update-check.service
      then
        systemctl --user stop nixos-update-check.timer
      fi
    }

    case "$choice" in
      now|*"Jetzt"*)    exec ${nixos-update-gui}/bin/nixos-update-gui ;;
      1h|*"1 Stunde"*)  snooze "+1 hour" ;;
      8h|*"8 Stunden"*) snooze "+8 hours" ;;
      1d|*"Morgen"*)    snooze "+24 hours" ;;
      *)                snooze "+24 hours" ;;   # aktiv weggewischt -> bewusst bis morgen
    esac
  '';
in
{
  environment.systemPackages = with pkgs; [
    libnotify          # notify-send im PATH (fuer Debugging; der Timer bringt es selbst mit)
    nvd                # lesbare Closure-Diffs; update-all.sh nutzt es (Fallback: nix store diff-closures)
    nixos-update-gui
    # Desktop-Icon: Update-Knopf -> oeffnet konsole und faehrt update-all.sh
    # (Flake bumpen + Host + alle konfigurierten VMs). sudo-Passwort gibst du im Terminal ein.
    (makeDesktopItem {
      name = "nixos-update-all";
      desktopName = "NixOS aktualisieren";
      comment = "Flake bumpen, Host und alle konfigurierten VMs neu bauen";
      exec = "nixos-update-gui";
      icon = "system-software-update";
      categories = [ "System" ];
      terminal = false;
    })
  ];

  # ===== Firmware/BIOS via LVFS (fwupd) =====
  # Daemon + fwupdmgr; Abschnitt 5 in update-all.sh nutzt das (pruefen -> [j/N]-Gate ->
  # anwenden; ein bestaetigtes BIOS-Update rebootet direkt). Generisch unbedenklich:
  # Geraete ohne LVFS-Angebot (z. B. manche Consumer-Boards) melden schlicht
  # nichts -> der Skript-Abschnitt ueberspringt dann still. Nebenwirkung: auch Plasma
  # Discover zeigt Firmware-Updates an. LVFS hinkt Dell gelegentlich eine Version
  # hinterher — bei Security-BIOS lohnt der Gegencheck auf dell.com.
  services.fwupd.enable = true;

  # ===== Update-Benachrichtigung (stuendlicher Check, Snooze, Desktop-Notification) =====
  # Bewusst KEIN system.autoUpgrade: nichts aktualisiert unbeaufsichtigt (insb. die VM darf das nie —
  # ein Redeploy killt eine laufende Zed-Sitzung). Stattdessen: erinnern -> du drueckst den Knopf.
  systemd.user.services.nixos-update-check = {
    description = "Auf NixOS-Updates pruefen und benachrichtigen (mit Snooze)";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${nixos-update-check}";
    };
  };
  systemd.user.timers.nixos-update-check = {
    description = "Stuendlicher Check auf NixOS-Updates";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;            # verpasste Laeufe nach Aufwachen/Boot nachholen (= auch "beim Start")
      RandomizedDelaySec = "10m";
    };
  };
}
