{ pkgs, self, system }:
pkgs.python3Packages.buildPythonPackage rec {
  pname = "swh.objstorage";
  version = "0.2.3";

  src = self.inputs.swh-objstorage;

  doCheck = false;

  propagatedBuildInputs = with pkgs.python3Packages; [
    # requirements.txt
    aiohttp
    click

    # requirements-swh.txt
    self.packages.${system}.swh-core
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
    homepage = "https://forge.softwareheritage.org/source/swh-objstorage/";
    license = licenses.gpl3Only;
  };
}
