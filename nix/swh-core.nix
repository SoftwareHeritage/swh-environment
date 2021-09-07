{ pkgs, self, system }:
pkgs.python3Packages.buildPythonPackage rec {
  pname = "swh.core";
  version = "0.14.5";

  src = self.inputs.swh-core;

  # FIXME: tests disabled for now, some packages missing in nixpkgs (types-click
  #        for instance, which shouldn't be needed anymore since click v8.0
  #        which ships type annotations directly) (PR to upstream?)
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


    # TODO: should be only needed for tests, figure out if there's a way to not
    #       put it in propagated inputs (putting it in `checkInputs` doesn't
    #       make it available for building `swh-storage` for example)
    self.packages.${system}.pytest-postgresql
  ];

  # HACK: flakes don't include the `.git/` folder as part of the source, so
  #       setuptools fails because it can't identify the version this way, so we
  #       provide it explicitely.
  prePatch = ''
                substituteInPlace setup.py \
                  --replace 'setup_requires=["setuptools-scm"],' "" \
                  --replace "use_scm_version=True" 'version="${version}"'
              '';

  meta = with pkgs.lib; {
    homepage = "https://forge.softwareheritage.org/source/swh-core/";
    license = licenses.gpl3Only;
  };
}
