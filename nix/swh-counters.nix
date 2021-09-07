{ pkgs, self, system }:
pkgs.python3Packages.buildPythonPackage rec {
  pname = "swh.counters";
  version = "0.36.0";

  src = self.inputs.swh-counters;

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
    flask
    redis

    # requirements-swh.txt
    self.packages.${system}.swh-core
    self.packages.${system}.swh-journal
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
    homepage = "https://forge.softwareheritage.org/source/swh-counters/";
    license = licenses.gpl3Only;
  };
}
