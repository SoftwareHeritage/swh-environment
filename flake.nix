{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
        {
          defaultPackage = self.packages.${system}.swh-model;

          packages = {
            attrs-strict = pkgs.python3Packages.buildPythonPackage rec {
              pname = "attrs_strict";
              version = "0.2.1";

              src = pkgs.python3Packages.fetchPypi {
                inherit pname version;
                sha256 = "1kz042af2ghw90mz9qf3v1jsivz1q3c12zkz3qifgwaym4av3c2q";
              };

              propagatedBuildInputs = with pkgs.python3Packages; [
                attrs
                setuptools_scm
              ];

              meta = with pkgs.lib; {
                homepage = "https://github.com/bloomberg/attrs-strict";
                description = "attrs runtime validation";
                license = licenses.asl20;
              };
            };

            swh-model = pkgs.python3Packages.buildPythonPackage rec {
              pname = "swh.model";
              version = "2.8.0";

              src = pkgs.python3Packages.fetchPypi {
                inherit pname version;
                sha256 = "0g1crlfv10f994jkz0bm3cv5kgwvr0a07m7h2810xyg2ikvszgxk";
              };

              propagatedBuildInputs = with pkgs.python3Packages; [
                attrs
                click
                dateutil
                deprecated
                dulwich
                hypothesis
                iso8601
                pytest
                pytz
                setuptools
                setuptools_scm
                typing-extensions

                self.packages.${system}.attrs-strict
              ];

              meta = with pkgs.lib; {
                homepage = "https://forge.softwareheritage.org/source/swh-model/";
                license = licenses.gpl3Only;
              };
            };
          };
        });
}
