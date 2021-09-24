{ pkgs, self, system }:
{
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

  mirakuru = pkgs.python3Packages.buildPythonPackage rec {
    pname = "mirakuru";
    version = "2.4.1";

    src = pkgs.python3Packages.fetchPypi {
      inherit pname version;
      sha256 = "sha256-cCXRIdLwTpV71q4yOVMdYOu6eHg5yJ1gUkeb61iwzQs=";
    };

    propagatedBuildInputs = with pkgs.python3Packages; [
      psutil
      pytest
      pytest-cov
      coverage
      python-daemon
      docutils
    ];

    meta = with pkgs.lib; {
      homepage = "https://github.com/ClearcodeHQ/mirakuru";
      description = ''
        A python library that starts your subprocess and waits for a clear
        indication, that it's running (process orchestrator)
      '';
      license = licenses.lgpl3Only;
    };
  };

  pytest-postgresql = pkgs.python3Packages.buildPythonPackage rec {
    pname = "pytest-postgresql";
    version = "3.1.1";

    src = pkgs.python3Packages.fetchPypi {
      inherit pname version;
      sha256 = "sha256-tpBUjRwd98qTOlCzLFZf5ZklpN3uSf52g9ryDHCL9kQ=";
    };

    propagatedBuildInputs = with pkgs.python3Packages; [
      pytest

      self.packages.${system}.mirakuru
      self.packages.${system}.port-for
    ];

    meta = with pkgs.lib; {
      homepage = "https://github.com/ClearcodeHQ/pytest-postgresql";
      description = ''
        This is a pytest plugin, that enables you to test your
        code that relies on a running PostgreSQL Database.
      '';
      license = licenses.lgpl3Only;
    };
  };

  port-for = pkgs.python3Packages.buildPythonPackage rec {
    pname = "port-for";
    version = "0.6.1";

    src = pkgs.python3Packages.fetchPypi {
      inherit pname version;
      sha256 = "sha256-ql3tvBOMYU1MydH/KlajSPbZiyGjVJeYf8YMCylZ9uQ=";
    };

    meta = with pkgs.lib; {
      homepage = "https://github.com/kmike/port-for";
      description = ''
        A command-line utility and a python library that helps with local TCP
        ports managment
      '';
      license = licenses.mit;
    };
  };

  py-tree-sitter = pkgs.python3Packages.buildPythonPackage rec {
    pname = "tree_sitter";
    version = "0.19.0";

    src = pkgs.python3Packages.fetchPypi {
      inherit pname version;
      sha256 = "sha256-hhr885+Vf911+LkxJLxAPy86vouB8QTAWxp0nm3TNJk=";
    };

    meta = with pkgs.lib; {
      homepage = "https://github.com/tree-sitter/py-tree-sitter";
      description = ''
        Python bindings to the tree-sitter library
      '';
      license = licenses.mit;
    };
  };
}
