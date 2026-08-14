# The generic half of a cattle container: everything true of every service
# deployed as a Nix-built Proxmox LXC template, and nothing specific to any one
# of them.
{ config, lib, pkgs, modulesPath, ... }:

let
  cfg = config.cattle;
in
{
  imports = [ "${modulesPath}/virtualisation/proxmox-lxc.nix" ];

  options.cattle = {
    name = lib.mkOption {
      type = lib.types.str;
      example = "streetfight";
      description = ''
        Service name. Names the template artifact, which is how the deployer
        recognises and garbage-collects this service's generations.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/data";
      description = ''
        Mountpoint holding everything that must outlive the container, or null
        for a stateless service. When set, the container refuses to finish
        booting unless the path really is a mountpoint.
      '';
    };
  };

  config = {
    proxmoxLXC = {
      privileged = false;
      # The container resource pins the address and MAC, so that a replacement
      # keeps the identity whatever is routing to it already has. Managing
      # either from inside would fight that.
      manageNetwork = false;
      manageHostName = false;
    };

    # Neither can work in an unprivileged container, and both fail noisily on
    # every boot if left enabled.
    systemd.mounts = [
      { enable = false; where = "/dev/mqueue"; }
      { enable = false; where = "/sys/fs/fuse/connections"; }
    ];

    # ⚠️ The filename is the deploy mechanism. The NixOS label carries the
    # nixpkgs revision and CI appends the app commit, so a change to either
    # yields a new name, and a new name is what replaces the container.
    image.baseName = "${cfg.name}-${config.system.nixos.label}";

    # local-lvm on the hypervisor is tight and a deploy transiently needs room
    # for two generations.
    documentation.enable = lib.mkDefault false;
    documentation.nixos.enable = lib.mkDefault false;

    # ⚠️ The upstream proxmox-lxc module turns sshd ON. Nothing can log in — no
    # passwords, no keys — but a cattle container has no shell worth reaching:
    # access is `pct enter` from the hypervisor, and the next deploy throws the
    # container away regardless. mkForce because upstream sets it unconditionally.
    services.openssh.enable = lib.mkForce false;

    time.timeZone = lib.mkDefault "Europe/London";
    system.stateVersion = lib.mkDefault "26.05";

    # multi-user.target *requires* this, so a stateDir that failed to attach
    # stops every service rather than letting one of them quietly write state
    # to a rootfs that is about to be thrown away.
    systemd.services.cattle-state-preflight = lib.mkIf (cfg.stateDir != null) {
      description = "Refuse to boot unless ${toString cfg.stateDir} is a mountpoint";
      before = [ "multi-user.target" ];
      requiredBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "cattle-state-preflight" ''
          if ${pkgs.util-linux}/bin/mountpoint -q ${cfg.stateDir}; then exit 0; fi
          echo "${cfg.stateDir} is not a mountpoint: state written there would not survive the next deploy" >&2
          exit 1
        '';
      };
    };
  };
}
