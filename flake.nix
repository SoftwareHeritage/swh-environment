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
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
        {
          defaultPackage = self.packages.${system}.swh-core;

          packages = {
            swh-core = pkgs.python3Packages.buildPythonPackage rec {
              pname = "swh.core";
              version = "0.14.4";

              src = self.inputs.swh-core;

              # FIXME: tests disabled for now, some packages missing in nixpkgs
              #        (types-click for instance, which shouldn't be needed
              #        anymore since click v8.0 which ships type annotations
              #        directly) (PR to upstream?)
              doCheck = false;

              /*

              buildInputs = with pkgs.python3Packages; [
                # requirements-test.txt
                hypothesis
                pre-commit
                pytest
                pytest-mock
                pytz
                requests-mock
                types-click
                types-flask
                types-pytz
                types-pyyaml
                types-requests

                # requirements-db-pytestplugin.txt
                pytest-postgresql
              ];

              */

              propagatedBuildInputs = with pkgs.python3Packages; [
                # requirements.txt
                click
                deprecated
                pyyaml
                sentry-sdk

                # requirements-db.txt
                psycopg2
                typing-extensions

                # requirements-http.txt
                aiohttp
                blinker
                flask
                iso8601
                msgpack
                requests

                self.packages.${system}.aiohttp-utils
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
                homepage = "https://forge.softwareheritage.org/source/swh-core/";
                license = licenses.gpl3Only;
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


            ###
            # TODO: third party packages below, upstream to nixpkgs?
            ###
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

            aiohttp-utils = pkgs.python3Packages.buildPythonPackage rec {
              pname = "aiohttp_utils";
              version = "3.1.1";

              src = pkgs.python3Packages.fetchPypi {
                inherit pname version;
                sha256 = "sha256-CPLE3BWj/Rk6qQSiH0/zZfW64LE6Z2Tz59BaO7gC3BQ=";
              };

              buildInputs = with pkgs.python3Packages; [
                Mako
                pytest
                tox
                webtest-aiohttp
              ];

              propagatedBuildInputs = with pkgs.python3Packages; [
                aiohttp
                gunicorn
                python_mimeparse
              ];

              meta = with pkgs.lib; {
                homepage = "https://github.com/sloria/aiohttp-utils";
                description = "Handy utilities for building aiohttp.web applications";
                license = licenses.mit;
              };
            };

          };
        });
}
