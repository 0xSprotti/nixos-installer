{
  description = "NixOS — multi-host + VMs, auto-discovered aus hosts/ (Baustein A)";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko = { url = "github:nix-community/disko/latest"; inputs.nixpkgs.follows = "nixpkgs"; };
  };

  # ───────────────────────────────────────────────────────────────────────────
  # Auto-Discovery (Baustein A): Die nixosConfigurations werden aus hosts/
  # abgeleitet — ein neuer Host oder eine neue VM ist NUR ein neuer Ordner,
  # kein Flake-Edit mehr. Konvention:
  #
  #   hosts/<name>/configuration.nix           Pflicht. Ordner OHNE diese Datei
  #                                            werden ignoriert (erlaubt
  #                                            schrittweises Onboarding, z. B.
  #                                            erst DETECTED-HARDWARE.txt ablegen).
  #   hosts/<name>/hardware-configuration.nix  vorhanden = PHYSISCHER Host:
  #                                            disko-Modul + disk.nix +
  #                                            hardware-configuration.nix werden
  #                                            automatisch mit eingebunden.
  #                                            disk.nix MUSS dann existieren —
  #                                            fehlt sie, bricht die Evaluation
  #                                            laut (gewollt, kein stiller Host
  #                                            ohne Disk-Layout).
  #   ohne hardware-configuration.nix          = VM: nur configuration.nix
  #                                            (Image via nixos-rebuild
  #                                            build-image, s. deploy-Skripte).
  #
  # Neuer Host = hosts/<name>/ mit den drei Dateien anlegen
  # (hardware-configuration.nix via `nixos-generate-config`, disk.nix als
  # disko-Layout des Geraets, configuration.nix nach dem Muster
  # eines bestehenden Hosts) — fertig,
  # das Flake findet den Host von selbst. WICHTIG wie immer: `git add -A`,
  # sonst sind neue Dateien fuer die Flake-Evaluation unsichtbar.
  # ───────────────────────────────────────────────────────────────────────────
  outputs = { self, nixpkgs, disko, ... }:
    let
      lib = nixpkgs.lib;
      hostsDir = ./hosts;

      # Alle Unterordner von hosts/, die eine configuration.nix tragen.
      hostNames = lib.filter
        (name: builtins.pathExists (hostsDir + "/${name}/configuration.nix"))
        (lib.attrNames
          (lib.filterAttrs (_: type: type == "directory") (builtins.readDir hostsDir)));

      # Physischer Host <=> hardware-configuration.nix liegt im Ordner.
      isPhysical = name:
        builtins.pathExists (hostsDir + "/${name}/hardware-configuration.nix");

      mkHost = name: nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules =
          lib.optionals (isPhysical name) [
            disko.nixosModules.disko
            (hostsDir + "/${name}/disk.nix")
            (hostsDir + "/${name}/hardware-configuration.nix")
          ]
          ++ [ (hostsDir + "/${name}/configuration.nix") ];
      };
    in {
      nixosConfigurations = lib.genAttrs hostNames mkHost;
    };
}
