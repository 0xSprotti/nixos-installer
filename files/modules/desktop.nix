# modules/desktop.nix
# ─────────────────────────────────────────────────────────────────────────────
# Geteilter Desktop-/Basis-Stack fuer alle Arbeits-Maschinen der Flotte.
# Enthaelt bewusst NICHTS Hardware- oder Person-Spezifisches:
#   - Hardware  -> hosts/<host>/hardware-configuration.nix + disk.nix
#   - Person    -> hosts/<host>/configuration.nix (User, hostName, dGPU-Blacklist, Bluetooth)
# So bleibt dieses Modul generisch (und damit gefahrlos teilbar/veroeffentlichbar).
{ lib, pkgs, ... }:
{
  # ===== Bootloader: UEFI + systemd-boot (KEIN GRUB) =====
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;   # ESP nicht mit alten Generationen volllaufen lassen
  boot.loader.efi.canTouchEfiVariables = true;
  # GRUB explizit aus: bootet ueber systemd-boot. Verhindert die Assertion
  # "boot.loader.grub.devices muss gesetzt sein", egal ob GRUB sonst irgendwo aktiviert wuerde.
  boot.loader.grub.enable = false;
  boot.initrd.systemd.enable = true;

  # ===== Kernel: Mainline (latest) statt LTS — fleet-weiter VORSCHLAGSWERT =====
  # Grund: Der LTS-i915 scheiterte auf Meteor Lake an MST-Daisy-Chains mit hoher
  # Bandbreite (DSC over MST) — Kette lief unter Windows, unter NixOS UND Kubuntu
  # kam nur Monitor 1; mit Mainline (7.1.4) sofort beide (Referenz-Laptop
  # Dell Latitude 5550, 2026-07-20). ACHTUNG plattformabhaengig — Fehlerbild,
  # Grenzen und Betriebsgrenze der Fleet: troubleshooting.md, Abschnitt J.
  # install.sh fragt die Wahl bei Neuinstallationen ab (Default J).
  # mkDefault: der Host uebersteuert mit NORMALER Zuweisung (kein mkForce noetig):
  #   boot.kernelPackages = pkgs.linuxPackages;   # in hosts/<host>/configuration.nix
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_latest;

  # ===== Basis-Hardware / -System =====
  hardware.enableRedistributableFirmware = true;   # WLAN-/GPU-Firmware
  hardware.graphics.enable = true;                 # iGPU / Desktop (+ lavapipe-Vulkan in der dev-VM)
  zramSwap.enable = true;

  networking.networkmanager.enable = true;

  # ===== Sprache / Zeit / Tastatur — personalisierbare VORSCHLAGSWERTE =====
  # mkDefault (Prioritaet 1000): der Installer schreibt die Prompt-Antworten als
  # NORMALE Zuweisungen (100) in hosts/<host>/configuration.nix — sie gewinnen
  # ohne mkForce. Fleet-Invarianten (Bootloader, Plasma, Nix-Features, Unfree-
  # Liste) stehen bewusst OHNE mkDefault: dort soll ein Host nur mit explizitem
  # mkForce abweichen koennen. Prioritaeten-Referenz: nixos-cheatsheet.md §13.
  time.timeZone = lib.mkDefault "Europe/Berlin";
  i18n.defaultLocale = lib.mkDefault "de_DE.UTF-8";
  services.xserver.xkb.layout = lib.mkDefault "de,gb";
  services.xserver.xkb.options = lib.mkDefault "grp:alt_shift_toggle";
  console.useXkbConfig = true;

  # ===== Desktop: Plasma 6 auf SDDM =====
  services.xserver.enable = true;
  services.displayManager.sddm.enable = true;
  services.desktopManager.plasma6.enable = true;

  # ===== Nix =====
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ===== Unfree-Ausnahmen (ZENTRAL — einzige Definitionsstelle im Host) =====
  # ACHTUNG: allowUnfreePredicate ist eine Funktion und damit NICHT mergefaehig — eine
  # zweite Definition in einem anderen Modul bricht die Evaluation bzw. ueberschreibt sie
  # still. Weitere Ausnahmen gehoeren deshalb HIER in die Liste, nirgendwo sonst.
  #  - brave:      Host-Browser fuer interne Anwendungen (s. systemPackages unten);
  #                Nebeneffekt (gewollt): erlaubt die Logo-Extraktion aus pkgs.brave in
  #                modules/browser-vm-host.nix (echtes Icon fuer die VM).
  #  - nvidia-x11: NVIDIA-Treiber fuer dGPU-Hosts (Referenz: RTX 2050 mit PRIME
  #                Offload + RTD3; Stromspar-Betrieb/D3cold: troubleshooting.md E).
  #                Auch mit open kernel module bleibt die Paket-Lizenz
  #                'unfreeRedistributable' (Userspace-Libs + GSP-Firmware proprietaer).
  #  - steam*:     Steam-Client + FHS-Huelle (programs.steam auf den Arbeits-Maschinen).
  # Die Liste erlaubt nur die EVALUATION dieser Pakete — installiert wird weiterhin nur,
  # was ein Host tatsaechlich referenziert.
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "brave"
    "nvidia-x11"
    "steam"
    "steam-unwrapped"
    "steam-original"
    "steam-run"
  ];

  # ===== Basis-Pakete (host-uebergreifend; dev-VM-Werkzeuge stehen in dev-vm-host.nix) =====
  environment.systemPackages = with pkgs; [
    vim git
    # Vertrauenswuerdiger Host-Browser fuer INTERNE Anwendungen (Intranet, Router-UIs,
    # lokale Dienste) — bewusst getrennt von der Wegwerf-browser-VM (Alltags-Surfen/Krypto).
    # Das Paket bringt seinen eigenen Startmenue-Eintrag "Brave Web Browser" (Normalmodus)
    # samt Original-Logo mit; der Inkognito-Eintrag unten kommt ZUSAETZLICH dazu.
    brave
    # Zweites Icon: startet Brave direkt im Inkognito-Modus — der Default-Weg fuer interne
    # Anwendungen (nichts landet in Verlauf/Cookies ueber die Sitzung hinaus). Keine
    # Policy-Erzwingung: der Normalmodus bleibt ueber den Paket-Eintrag jederzeit waehlbar.
    # Hinweis Inkognito-Semantik: Extensions sind dort per Chromium-Default deaktiviert,
    # Logins/Cookies leben nur bis zum Schliessen des letzten Inkognito-Fensters.
    # icon = Theme-Name "brave-browser": loest auf die hicolor-Icons auf, die das
    # brave-Paket selbst installiert (share/icons/hicolor/*/apps/brave-browser.png).
    (makeDesktopItem {
      name = "brave-incognito";
      desktopName = "Brave (Inkognito)";
      comment = "Brave im Inkognito-Modus starten (fuer interne Anwendungen)";
      exec = "brave --incognito %U";
      icon = "brave-browser";
      categories = [ "Network" "WebBrowser" ];
      terminal = false;
    })
  ];
}
