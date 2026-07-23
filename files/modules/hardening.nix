# modules/hardening.nix
# ─────────────────────────────────────────────────────────────────────────────
# Host-Haertung nach BSI IT-Grundschutz SYS.2.3 (Clients unter Linux und Unix),
# Zielbild: Basis + Standard + erhoehter Schutzbedarf (H) auf den PHYSISCHEN
# Arbeits-Maschinen der Flotte. VMs importieren dieses Modul NICHT —
# sie sind selbst die kompensierende Massnahme (Isolation exponierter Workloads).
#
# Abdeckung (Details + Erlaeuterungstexte fuer den GSC: README-hardening.md):
#   A6  (S) Wechsellaufwerke: kein Automount-Zwang, udisks2 mountet noexec/nosuid/nodev
#   A8  (S) AppArmor-LSM aktiv; Profilsatz auf NixOS faktisch leer -> Wirkung wird
#           NixOS-nativ ueber systemd erbracht (Dienst-Maskierung + Sandboxing, s. unten)
#   A11 (S) Ueberlauf-Schutz: nix-GC + min-free/max-free + journald-Deckel
#   A14 (H) USBGuard: Whitelist aus dem Repo (deklarativ = "zentral verwaltet")
#   A17 (H) via VM-Isolation + Dienst-Maskierung/-Sandboxing (Messverfahren: README)
#   A18 (H) sysctl-Haertung statt hardened Kernel (Begruendung: libvirt/VFIO-Rueckgrat)
#   A20 (H) SysRq auf 16 (nur Sync) — NixOS-Default, hier explizit/deterministisch
#
# BEWUSST NICHT umgesetzt (dokumentierte Abweichungen, s. README-hardening.md):
#   A15 (H) noexec auf /home — bricht Zed/Language-Server; Entwicklung laeuft in der dev-VM
#   linuxPackages_hardened — Konflikt-Risiko mit Virtualisierung/User-Namespaces
{ config, lib, pkgs, ... }:

let
  cfg = config.hardening;

  # Gemeinsamer Sandbox-Satz fuer die simplen libvirt-Helfer-Daemons (Block (c)
  # unten): kein exec, ausschliesslich Unix-Sockets, klar umrissene Schreibpfade
  # (je Daemon via ReadWritePaths ergaenzt).
  # Stufe 3 (umgesetzt 2026-07-21, nur die drei Helfer — acpid s. Block (b)):
  #   CapabilityBoundingSet = "" — kompletter Drop. Die Helfer brauchen als
  #     root mit ausschliesslich root-eigenen Dateien/Verzeichnissen keine
  #     einzige Capability (Eigentuemer-Zugriff laeuft ohne DAC_OVERRIDE).
  #   SystemCallFilter = @system-service — das erprobte systemd-Standardset;
  #     deckt sendmsg/SCM_RIGHTS (FD-Durchreichen an qemu) und execve
  #     (virtlogd-Re-Exec) ab. Handgeschnitzte Listen bewusst NICHT (Pflege-
  #     aufwand ohne belastbaren Mehrwert bei diesen drei Daemons).
  #   Verletzungen enden per Default in sichtbarem SIGSYS im Journal —
  #     bewusst laut statt stiller Degradation.
  virtHelperSandbox = {
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    SystemCallFilter = [ "@system-service" ];
    PrivateTmp = true;
    ProtectSystem = "strict";            # exakt umrissene rw-Pfade je Daemon
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectProc = "invisible";
    PrivateNetwork = true;               # beide Sockets sind Unix -> kein Netz noetig
    RestrictAddressFamilies = [ "AF_UNIX" ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    SystemCallArchitectures = "native";
  };
in
{
  options.hardening = {
    usbguard.rulesFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Pfad zur gepinnten USBGuard-Regeldatei des Hosts (Ausgabe von
        `sudo usbguard generate-policy`, im Repo eingecheckt). null = USBGuard aus —
        konservativer Default, damit ein neuer Host ohne eigene Regelliste nicht
        versehentlich alle USB-Geraete blockt. Pro Host eine EIGENE Datei erzeugen
        (die Regeln tragen geraetespezifische Hashes/Ports).
      '';
      example = lib.literalExpression "./usbguard-rules.conf";
    };
  };

  config = {
    # ===== A6 — Wechsellaufwerke (S) ==========================================
    # Plasma mountet nicht automatisch (Geraete-Benachrichtigung = manueller Klick);
    # hier wird deklarativ festgeschrieben, WOMIT udisks2 mountet, wenn gemountet
    # wird: nie ausfuehrbar, nie setuid, keine Geraetedateien. Gilt fuer alle per
    # udisks eingebundenen Wechseldatentraeger (USB-Stick, SD-Karte, …).
    services.udisks2.settings."mount_options.conf".defaults = {
      defaults = "rw,nosuid,nodev,noexec";
    };

    # ===== A8 — AppArmor (S) ==================================================
    # Kernel-LSM aktiv. Ehrlicher Befund (empirisch, 2026-07-20): der geladene
    # Profilsatz ist LEER — die Upstream-Sammlung (apparmor-profiles) adressiert
    # FHS-Pfade und greift auf NixOS-Store-Pfaden nicht. Das LSM bleibt bewusst an
    # (kostenneutral; Pakete mit eigenen Profilen koennen andocken), die eigentliche
    # Rechtebeschraenkung erbringt der systemd-Baustein unten. Nebenbefund: aa-status
    # scheitert am leeren Profilsatz mit "Failed to get profiles: 2" — Tooling, kein
    # Sicherheitsproblem (s. troubleshooting.md, Abschnitt J).
    # killUnconfinedConfinables bleibt AUS (konservativ: kein Abschiessen laufender
    # Prozesse beim Profil-Reload).
    security.apparmor = {
      enable = true;
      packages = [ pkgs.apparmor-profiles ];
      killUnconfinedConfinables = false;
    };

    # ===== A8/A17-Ergaenzung — systemd-Dienst-Haertung ========================
    # Da AppArmor faktisch ohne Profile laeuft (s. oben), wird die Rechtebeschraenkung
    # einzelner Dienste NixOS-nativ ueber systemd erbracht. Bestandsaufnahme,
    # Korb-Einteilung und Nachmessung: README-hardening.md, Abschnitt
    # "systemd-analyze security" (Baseline Referenzgeraet 2026-07-20).
    #
    # (a) Angriffsflaeche ENTFERNEN statt sandboxen: die modularen libvirt-
    # Treiber-Daemons fuer nicht genutzte Hypervisoren (LXC, VirtualBox, Xen)
    # werden maskiert — dieser Verbund faehrt ausschliesslich QEMU/KVM
    # (virtqemud bleibt unangetastet). Die Sockets MUESSEN mit maskiert werden,
    # sonst belebt Socket-Aktivierung die Dienste wieder. enable=false maskiert
    # die Unit in NixOS (Symlink auf /dev/null); auf Hosts ohne libvirt: No-op.
    # Baseline-Wirkung: drei Eintraege mit Score 9.6 UNSAFE entfallen ersatzlos.
    #
    # (b) acpid sandboxen: kleiner root-Daemon (kam mit dem NVIDIA-Stack auf
    # dem Referenzgeraet), nimmt ACPI-Events via Netlink entgegen und startet Handler-
    # Skripte. Konservatives Sandboxing: Dateisystem weitgehend read-only,
    # nur AF_UNIX+AF_NETLINK, keine neuen Privilegien/Namespaces — die
    # Handler (acEvent/lidEvent/powerEvent) laufen unveraendert als root.
    # Guard: mkIf services.acpid.enable — auf Hosts OHNE acpid (z. B. ohne
    # NVIDIA-Stack) entsteht sonst eine leere Unit-Huelle. Verifiziert am Referenzgeraet
    # 2026-07-20: Score 9.6 UNSAFE -> 5.7 MEDIUM, AC-Events fehlerfrei.
    # Stufe 3 auch fuer acpid (umgesetzt 2026-07-23 — KURSKORREKTUR vom
    # 2026-07-22, dokumentiert):
    # Das Abnahmekriterium "zwei Wochen Normalbetrieb" (gesetzt 2026-07-21) wurde
    # nicht ausgesessen, sondern durch VOLLSTAENDIGE AUFZAEHLUNG ersetzt — die
    # empirische Handler-Inventur auf dem Referenzgeraet (confdir + alle action-Skripte im
    # Wortlaut) ergab: acEvent.sh/lidEvent.sh/powerEvent.sh sind LEERE
    # Bash-Skripte (Shebang, sonst nichts; im Repo ist kein *EventCommands
    # konfiguriert — Power-Management macht logind/Plasma). Damit ist das
    # Handler-Verhalten vollstaendig umrissen: Event -> Bash spawnen -> Exit.
    # Der "ueber Wochen verteilte Randfall" hat exakt denselben Codepfad wie der
    # Sofort-Test — dieselbe Logik wie bei der Helfer-Beschleunigung (Stufe 2/3).
    # Einziger theoretischer Rest beim Caps-Drop: der Netlink-EMPFANG der
    # ACPI-Events (braeuchte der Multicast-Join wider Erwarten eine Capability,
    # gaebe es KEIN SIGSYS, sondern stille Event-Taubheit) — deshalb ist der
    # kritische Verifikations-Check ein POSITIV-Beweis, nicht die Fehler-Suche.
    # VERFAHRENS-LEKTION (2026-07-23): acpid loggt empfangene Events NICHT ins
    # Journal ("event logging is off") — ein Journal-Grep belegt den Empfang
    # nie. Der Beweis laeuft ueber acpi_listen (liest live am acpid-Socket mit,
    # Binary im Store-Pfad der Unit) waehrend eines AC-Events.
    # Verifiziert am Referenzgeraet 2026-07-23: 5.7 MEDIUM -> 2.3 OK; acpi_listen zeigte
    # AC-Events beider Richtungen samt Battery-/Processor-Kaskaden live durch
    # den gesandboxten Daemon; voller Suspend/Resume-Zyklus; keine Denials.
    # Bewusst weiterhin NICHT gesetzt: ProtectSystem=strict — acpid legt Socket
    # und PID-Datei selbst unter /run an; strict braeuchte ReadWritePaths bei
    # geringem Mehrwert (Store ist ro, full deckt /usr,/boot,/etc).
    # Stufe 2 erledigt (2026-07-21): virtlogd/virtlockd/virtsecretd -> Block (c);
    # Stufe 3 (Caps + Syscall-Filter): Helfer 2026-07-21, acpid 2026-07-23.
    systemd.services = lib.genAttrs [ "virtlxcd" "virtvboxd" "virtxend" ]
      (_: { enable = false; })
    // {
      acpid = lib.mkIf config.services.acpid.enable {
        serviceConfig = {
          NoNewPrivileges = true;
          CapabilityBoundingSet = "";
          SystemCallFilter = [ "@system-service" ];
          PrivateTmp = true;
          ProtectSystem = "full";            # /usr,/boot,/etc read-only (Store ist ohnehin ro)
          ProtectHome = true;
          ProtectKernelModules = true;
          ProtectKernelLogs = true;
          ProtectControlGroups = true;
          ProtectClock = true;
          RestrictAddressFamilies = [ "AF_UNIX" "AF_NETLINK" ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          LockPersonality = true;
          SystemCallArchitectures = "native";
        };
      };

      # (c) virtlogd/virtlockd/virtsecretd sandboxen — Stufe 2, umgesetzt
      # 2026-07-21 (bewusst VOR Ablauf der Beobachtungsphase vorgezogen: die
      # drei Helfer sind vom acpid-Muster funktional unabhaengig, zwei davon
      # ohne aktive Nutzung idle, und die Funktionsprobe deckt den einzig
      # aktiven virtlogd unmittelbar ab). Profil aller drei: kein exec, nur
      # Unix-Sockets, exakt bekanntes Schreibset — deshalb BEWUSST schaerfer
      # als acpid (dessen root-Handler-Skripte machten strict dort
      # unkalkulierbar): ProtectSystem=strict, PrivateNetwork, nur AF_UNIX
      # (gemeinsamer Satz virtHelperSandbox im let oben).
      #   virtlogd   : oeffnet die Gast-Logs (/var/log/libvirt/qemu/*) und
      #                reicht die FDs an qemu durch -> /var/log/libvirt rw.
      #   virtlockd  : ohne lock_manager="lockd" idle; /var/lib/libvirt rw,
      #                damit eine SPAETERE lockd-Aktivierung (Leases bzw.
      #                Direkt-Locks auf Images) nicht stumm braeche.
      #   virtsecretd: ohne genutzte Secrets idle; bewusst NICHT maskiert
      #                (virtqemud weckt ihn bei Bedarf per Socket, z. B. fuer
      #                kuenftige LUKS-Gast-Disks); Secrets liegen auf NixOS
      #                unter /var/lib/libvirt (sysconfdir-Anpassung des
      #                Pakets) -> abgedeckt.
      #   /run/libvirt rw fuer alle drei (Sockets, Re-Exec-State).
      # virtqemud bleibt BEWUSST ungehaertet — dokumentierte Abweichung
      # (README-hardening.md): er spawnt qemu mit breitem Device-/cgroup-/
      # Namespace-Bedarf; die Rechtebegrenzung des QEMU-Pfads erbringen
      # VM-Grenze + nftables-Isolation (A17).
      # AUSROLLEN: der switch restartet virtlogd BEWUSST NICHT (NixOS-Modul:
      # restartIfChanged=false — schuetzt Log-FDs laufender Gaeste; empirisch
      # 2026-07-21: "NOT restarting ... virtlogd.service"). Die Sandbox greift
      # erst nach MANUELLEM Neustart bei gestoppten VMs:
      #   sudo systemctl restart virtlogd
      # (virtlockd/virtsecretd sind i. d. R. inactive und starten beim
      # naechsten Socket-Accept bereits gesandboxt.) MESSFALLE: systemd-analyze
      # security bewertet die GELADENE Unit — der Score sieht schon vor dem
      # Neustart gut aus, der laufende Prozess ist aber noch unkonfiniert.
      # Nachmessung + Funktionsprobe erst NACH dem Neustart (README-hardening.md).
      # Verifiziert am Referenzgeraet 2026-07-21: je 9.6 UNSAFE -> 4.8 OK; Funktionsprobe
      # (dev-vm-Boot/-Log ueber die gesandboxte Instanz, ssh) fehlerfrei.
      # Guard mkIf libvirtd.enable: sonst leere Unit-Huellen ohne libvirt.
      virtlogd = lib.mkIf config.virtualisation.libvirtd.enable {
        serviceConfig = virtHelperSandbox // {
          ReadWritePaths = [ "/var/log/libvirt" "/run/libvirt" ];
        };
      };
      virtlockd = lib.mkIf config.virtualisation.libvirtd.enable {
        serviceConfig = virtHelperSandbox // {
          ReadWritePaths = [ "/var/lib/libvirt" "/run/libvirt" ];
        };
      };
      virtsecretd = lib.mkIf config.virtualisation.libvirtd.enable {
        serviceConfig = virtHelperSandbox // {
          ReadWritePaths = [ "/var/lib/libvirt" "/run/libvirt" ];
        };
      };
    };
    systemd.sockets = lib.genAttrs
      (lib.concatMap (d: [ d "${d}-ro" "${d}-admin" ]) [ "virtlxcd" "virtvboxd" "virtxend" ])
      (_: { enable = false; });

    # ===== A11 — Schutz vor Ueberlastung der Platte (S) =======================
    # Der realistische Vollaeufer auf NixOS ist /nix (ein btrfs-Pool, keine Quotas —
    # bewusste Entscheidung: qgroups kosten Pflege + Performance). Drei Deckel:
    #  1) woechentliche GC, Generationen aelter 14 Tage fallen weg
    #     (Rollback-Fenster bleibt 14 Tage; systemd-boot haelt ohnehin max. 10 Eintraege)
    #  2) min-free/max-free: laeuft der Store unter 2 GiB frei, raeumt Nix beim
    #     Bauen selbststaendig bis 8 GiB frei — faengt den Vollaeufer WAEHREND
    #     eines grossen Builds, wo der Wochen-Timer nicht hilft
    #  3) journald gedeckelt (Logs liegen auf dem eigenen Subvolume /var/log)
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 14d";
    };
    nix.settings = {
      min-free = 2 * 1024 * 1024 * 1024;   # 2 GiB
      max-free = 8 * 1024 * 1024 * 1024;   # 8 GiB
    };
    services.journald.extraConfig = ''
      SystemMaxUse=1G
    '';

    # ===== A14 — USBGuard (H) =================================================
    # Whitelist = eingecheckte Regeldatei (Option oben) -> "zentral verwaltete
    # Whitelist" ist woertlich das Git-Repo. Neue Geraete: erst blocken lassen,
    # dann Regel nachziehen (Workflow: README-hardening.md).
    #   - implicitPolicyTarget block: alles ohne Regel wird blockiert
    #   - presentControllerPolicy keep: Controller beim Daemon-Start NIE
    #     deautorisieren (Lockout-Schutz)
    #   - IPC fuer wheel: 'usbguard list-devices' & Notifier ohne root
    services.usbguard = lib.mkIf (cfg.usbguard.rulesFile != null) {
      enable = true;
      ruleFile = cfg.usbguard.rulesFile;
      implicitPolicyTarget = "block";
      presentDevicePolicy = "apply-policy";
      insertedDevicePolicy = "apply-policy";
      presentControllerPolicy = "keep";
      IPCAllowedGroups = [ "wheel" ];
    };

    # Sichtbarkeitsschicht: Desktop-Benachrichtigung, sobald ein Geraet
    # erlaubt/geblockt wird (kein Management — Regeln kommen NUR aus dem Repo).
    systemd.user.services.usbguard-notifier = lib.mkIf (cfg.usbguard.rulesFile != null) {
      description = "USBGuard Desktop-Benachrichtigungen (allow/block-Ereignisse)";
      wantedBy = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.usbguard-notifier}/bin/usbguard-notifier";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # ===== A18 — Kernel-Haertung per sysctl (H) ===============================
    # Statt linuxPackages_hardened (Konflikt-Risiko mit libvirt/VFIO/User-Namespaces;
    # die BSI-Beispiele grsecurity/PaX sind seit 2017 nicht mehr frei verfuegbar).
    # User-Namespaces bleiben bewusst AN (Nix-Build-Sandbox braucht sie).
    boot.kernel.sysctl = {
      # A20: SysRq nur Sync (NixOS-Default — hier explizit, damit deterministisch)
      "kernel.sysrq" = 16;
      # Kernel-Adressen nicht an Userspace verraten (erschwert Exploit-Entwicklung)
      "kernel.kptr_restrict" = 2;
      # dmesg nur fuer root (Kernel-Log leakt Adressen/Hardware-Details)
      "kernel.dmesg_restrict" = 1;
      # BPF nur fuer privilegierte Prozesse + JIT-Haertung (haeufiger LPE-Vektor)
      "kernel.unprivileged_bpf_disabled" = 1;
      "net.core.bpf_jit_harden" = 2;
      # ptrace nur auf eigene Kindprozesse (yama) — bremst Credential-Harvesting
      "kernel.yama.ptrace_scope" = 1;
      # kexec aus: kein Laden eines Ersatz-Kernels zur Laufzeit (bis zum Reboot fix)
      "kernel.kexec_load_disabled" = 1;
      # keine Coredumps von setuid-Programmen
      "fs.suid_dumpable" = 0;
      # Link-/FIFO-Schutz in world-writable Verzeichnissen (haertet /tmp-Angriffe ab)
      "fs.protected_symlinks" = 1;
      "fs.protected_hardlinks" = 1;
      "fs.protected_fifos" = 2;
      "fs.protected_regular" = 2;
    };

    # ===== Deterministik: Firewall explizit an (NixOS-Default, festgeschrieben) =
    networking.firewall.enable = true;
  };
}
