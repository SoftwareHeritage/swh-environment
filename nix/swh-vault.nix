{ pkgs, self, system }:
pkgs.python3Packages.buildPythonPackage rec {
  pname = "swh.vault";
  version = "1.2.0";

  src = self.inputs.swh-vault;

  # NOTE: tests are just a whole mess, need more investigation
  doCheck = false;

  propagatedBuildInputs = with pkgs.python3Packages; [
    # requirements.txt
    click
    fastimport
    flask
    psycopg2
    python-dateutil
    typing-extensions

    # requirements-swh.txt
    self.packages.${system}.swh-core
    self.packages.${system}.swh-model
    self.packages.${system}.swh-objstorage
    self.packages.${system}.swh-scheduler
    self.packages.${system}.swh-storage

    # requirements-swh-graph.txt
    self.packages.${system}.swh-graph
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
    homepage = "https://forge.softwareheritage.org/source/swh-vault/";
    license = licenses.gpl3Only;
  };
}
