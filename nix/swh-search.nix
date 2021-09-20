{ pkgs, self, system }:
pkgs.python3Packages.buildPythonPackage rec {
  pname = "swh.search";
  version = "0.11.4";

  src = self.inputs.swh-search;

  # NOTE: tests are just a whole mess, need more investigation
  doCheck = false;

  propagatedBuildInputs = with pkgs.python3Packages; [
    # requirements.txt
    click
    elasticsearch
    typing-extensions


    # FIXME: python bindings to tree-sitter needs packaging
    # tree_sitter

    # requirements-swh.txt
    self.packages.${system}.swh-core
    self.packages.${system}.swh-indexer
    self.packages.${system}.swh-journal
    self.packages.${system}.swh-model
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
    homepage = "https://forge.softwareheritage.org/source/swh-search/";
    license = licenses.gpl3Only;
  };
}
