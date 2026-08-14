{
  description = "Proxmox LXC templates built with Nix and deployed as cattle";

  # Deliberately input-free: the consumer passes its own nixpkgs to mkTemplate,
  # so the template is built from the flake.lock of the app repo rather than
  # from a revision pinned here.
  outputs = { self }: {
    nixosModules.cattle = ./modules/cattle.nix;

    lib.mkTemplate =
      { nixpkgs
      , name
      , system ? "x86_64-linux"
      , stateDir ? null
      , modules ? [ ]
      }:
      let
        host = nixpkgs.lib.nixosSystem {
          modules = [
            { nixpkgs.hostPlatform = system; }
            self.nixosModules.cattle
            { cattle = { inherit name stateDir; }; }
          ] ++ modules;
        };
      in
      {
        nixosConfigurations."${name}-lxc" = host;
        packages.${system}.proxmoxLxcTemplate = host.config.system.build.tarball;
      };
  };
}
