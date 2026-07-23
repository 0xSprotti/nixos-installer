# modules/vfio.nix — geteiltes Passthrough-Modul (AUTO-GENERIERT, danach frei editierbar).
# Jede VM, die ein PCI-Geraet durchreicht, traegt nur ihre IDs zu host.passthroughIds bei
# (Listen mergen in NixOS automatisch). Daraus baut dieses Modul EINE vfio-pci-Bindung +
# IOMMU + libvirt. Aktiv nach 'nixos-rebuild switch' + REBOOT (Kernel-Parameter).
{ config, lib, ... }:
let
  cfg = config.host;
in
{
  options.host.passthroughIds = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "10de:25a9" "8086:7e40" ];
    description = "PCI vendor:device-IDs, die an vfio-pci gebunden werden (VM-Passthrough).";
  };

  options.host.passthroughUser = lib.mkOption {
    type = lib.types.str;
    default = "";
    example = "alice";
    description = "Optionaler Benutzer, der fuer sudo-loses virsh in die libvirtd-Gruppe kommt.";
  };

  config = lib.mkIf (cfg.passthroughIds != [ ]) (lib.mkMerge [
    {
      # intel_iommu/amd_iommu sind je auf der anderen Plattform ein No-op -> beide unbedingt
      # setzbar, keine CPU-Erkennung noetig.
      boot.kernelParams = [
        "intel_iommu=on"
        "amd_iommu=on"
        "iommu=pt"
        "vfio-pci.ids=${lib.concatStringsSep "," (lib.unique cfg.passthroughIds)}"
      ];
      # vfio frueh laden, damit das Binding VOR den normalen Treibern greift.
      boot.initrd.kernelModules = [ "vfio_pci" "vfio_iommu_type1" "vfio" ];
      # libvirt/KVM, um die durchgereichten Geraete in VMs zu nutzen.
      virtualisation.libvirtd.enable = true;
    }
    (lib.mkIf (cfg.passthroughUser != "") {
      users.users.${cfg.passthroughUser}.extraGroups = [ "libvirtd" ];
    })
  ]);
}
