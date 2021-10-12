{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    swh-auth = {
      url = "git+https://forge.softwareheritage.org/source/swh-auth.git?tag=v0.6.1";
      flake = false;
    };
    swh-core = {
      url = "git+https://forge.softwareheritage.org/source/swh-core.git?tag=v0.14.5";
      flake = false;
    };
    swh-counters = {
      url = "git+https://forge.softwareheritage.org/source/swh-counters.git?tag=v0.8.0";
      flake = false;
    };
    swh-graph = {
      url = "git+https://forge.softwareheritage.org/source/swh-graph.git?tag=v0.5.0";
      flake = false;
    };
    swh-indexer = {
      url = "git+https://forge.softwareheritage.org/source/swh-indexer.git?tag=v0.8.0";
      flake = false;
    };
    swh-journal = {
      url = "git+https://forge.softwareheritage.org/source/swh-journal.git?tag=v0.8.0";
      flake = false;
    };
    swh-model = {
      url = "git+https://forge.softwareheritage.org/source/swh-model.git?tag=v2.8.0";
      flake = false;
    };
    swh-objstorage = {
      url = "git+https://forge.softwareheritage.org/source/swh-objstorage.git?tag=v0.2.3";
      flake = false;
    };
    swh-scheduler = {
      url = "git+https://forge.softwareheritage.org/source/swh-scheduler.git?tag=v0.18.0";
      flake = false;
    };
    swh-search = {
      url = "git+https://forge.softwareheritage.org/source/swh-search.git?tag=v0.11.4";
      flake = false;
    };
    swh-storage = {
      url = "git+https://forge.softwareheritage.org/source/swh-storage.git?tag=v0.36.0";
      flake = false;
    };
    swh-vault = {
      url = "git+https://forge.softwareheritage.org/source/swh-vault.git?tag=v1.2.0";
      flake = false;
    };
    swh-web = {
      url = "git+https://forge.softwareheritage.org/source/swh-web.git?tag=v0.0.332";
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
            swh-auth = import ./nix/swh-auth.nix { inherit self pkgs system; };
            swh-core = import ./nix/swh-core.nix { inherit self pkgs system; };
            swh-counters = import ./nix/swh-counters.nix { inherit self pkgs system; };
            swh-graph = import ./nix/swh-graph.nix { inherit self pkgs system; };
            swh-indexer = import ./nix/swh-indexer.nix { inherit self pkgs system; };
            swh-journal = import ./nix/swh-journal.nix { inherit self pkgs system; };
            swh-model = import ./nix/swh-model.nix { inherit self pkgs system; };
            swh-objstorage = import ./nix/swh-objstorage.nix { inherit self pkgs system; };
            swh-scheduler = import ./nix/swh-scheduler.nix { inherit self pkgs system; };
            swh-search = import ./nix/swh-search.nix { inherit self pkgs system; };
            swh-storage = import ./nix/swh-storage.nix { inherit self pkgs system; };
            swh-vault = import ./nix/swh-vault.nix { inherit self pkgs system; };
            swh-web = import ./nix/swh-web.nix { inherit self pkgs system; };
          } // (
            ###
            # TODO: third party packages below, upstream to nixpkgs?
            ###
            import ./nix/third-party.nix { inherit self pkgs system; }
          );
        });
}
