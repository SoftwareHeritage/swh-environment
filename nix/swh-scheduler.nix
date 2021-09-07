{ pkgs, self, system }:
pkgs.python3Packages.buildPythonPackage rec {
  pname = "swh.scheduler";
  version = "0.18.0";

  src = self.inputs.swh-scheduler;

  doCheck = false;

  buildInputs = with pkgs.python3Packages; [
    self.packages.${system}.pytest-postgresql
  ];

  propagatedBuildInputs = with pkgs.python3Packages; [
    # requirements.txt
    attrs
    celery
    click
    elasticsearch
    flask
    humanize
    pika
    psycopg2
    pyyaml
    requests
    setuptools
    typing-extensions

    self.packages.${system}.attrs-strict

    # requirements-swh.txt
    self.packages.${system}.swh-core
    self.packages.${system}.swh-storage
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
    homepage = "https://forge.softwareheritage.org/source/swh-scheduler/";
    license = licenses.gpl3Only;
  };
}
