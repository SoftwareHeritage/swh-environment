{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    swh-model = {
      url = "github:SoftwareHeritage/swh-model";
      flake = false;
    };
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

              src = self.inputs.swh-model;

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
                typing-extensions

                self.packages.${system}.attrs-strict
              ];

              # HACK: flakes don't include the `.git/` folder as part of the
              #       source, so setuptools fails because it can't identify the
              #       version this way, so we provide it explicitely.
              prePatch = ''
                substituteInPlace setup.py \
                  --replace 'setup_requires=["setuptools-scm"],' "" \
                  --replace "use_scm_version=True" 'version="${version}"'
              '';

              meta = with pkgs.lib; {
                homepage = "https://forge.softwareheritage.org/source/swh-model/";
                license = licenses.gpl3Only;
              };
            };
          };
        });
}
