{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    swh-core = {
      url = "git+https://forge.softwareheritage.org/source/swh-core.git";
      flake = false;
    };
    swh-model = {
      url = "git+https://forge.softwareheritage.org/source/swh-model.git";
      flake = false;
    };
    swh-objstorage = {
      url = "git+https://forge.softwareheritage.org/source/swh-objstorage.git";
      flake = false;
    };
    swh-scheduler = {
      url = "git+https://forge.softwareheritage.org/source/swh-scheduler.git";
      flake = false;
    };
    swh-storage = {
      url = "git+https://forge.softwareheritage.org/source/swh-storage.git";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
        {
          defaultPackage = self.packages.${system}.swh-core;

          packages = {
            swh-core = import ./nix/swh-core.nix { inherit self pkgs system; };
            swh-model = import ./nix/swh-model.nix { inherit self pkgs system; };
            swh-objstorage = import ./nix/swh-objstorage.nix { inherit self pkgs system; };
            swh-scheduler = import ./nix/swh-scheduler.nix { inherit self pkgs system; };
            swh-storage = import ./nix/swh-storage.nix { inherit self pkgs system; };
          } // (
            ###
            # TODO: third party packages below, upstream to nixpkgs?
            ###
            import ./nix/third-party.nix { inherit self pkgs system; }
          );
        });
}
