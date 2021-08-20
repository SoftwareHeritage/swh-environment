{ pkgs, self }:
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
}
