{ pkgs, self, system }:
pkgs.python3Packages.buildPythonPackage rec {
  pname = "swh.indexer";
  version = "0.8.0";

  src = self.inputs.swh-indexer;

  doCheck = false;

  propagatedBuildInputs = with pkgs.python3Packages; [
    # requirements.txt
    click
    PyLD
    python_magic
    typing-extensions
    xmltodict

    # requirements-swh.txt
    self.packages.${system}.swh-core
    self.packages.${system}.swh-journal
    self.packages.${system}.swh-scheduler
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
    homepage = "https://forge.softwareheritage.org/source/swh-indexer/";
    license = licenses.gpl3Only;
  };
}
