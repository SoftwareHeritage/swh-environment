{ pkgs, self, system }:
pkgs.python3Packages.buildPythonPackage rec {
  pname = "swh.storage";
  version = "0.36.0";

  src = self.inputs.swh-storage;

  # NOTE: tests are just a whole mess, need more investigation
  doCheck = false;
  checkPhase = "tox";
  checkInputs = with pkgs.python3Packages; [
    tox

    black
    flake8
    mypy
  ];

  propagatedBuildInputs = with pkgs.python3Packages; [
    # requirements.txt
    aiohttp
    cassandra-driver
    click
    deprecated
    flask
    iso8601
    mypy-extensions
    psycopg2
    tenacity
    typing-extensions

    # requirements-swh.txt
    self.packages.${system}.swh-core
    self.packages.${system}.swh-counters
    self.packages.${system}.swh-model
    self.packages.${system}.swh-objstorage
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
    homepage = "https://forge.softwareheritage.org/source/swh-storage/";
    license = licenses.gpl3Only;
  };
}
