{ self, pkgs, system }:
pkgs.python3Packages.buildPythonPackage rec {
  pname = "swh.model";
  version = "2.8.0";

  src = self.inputs.swh-model;

  propagatedBuildInputs = with pkgs.python3Packages; [
    attrs
    click
    dateutil
    deprecated
    dulwich
    hypothesis
    iso8601
    pytest
    pytz
    setuptools
    typing-extensions

    self.packages.${system}.attrs-strict
  ];

  # HACK: flakes don't include the `.git/` folder as part of the
  #       source, so setuptools fails because it can't identify the
  #       version this way, so we provide it explicitely.
  prePatch = ''
                substituteInPlace setup.py \
                  --replace 'setup_requires=["setuptools-scm"],' "" \
                  --replace "use_scm_version=True" 'version="${version}"'
              '';

  meta = with pkgs.lib; {
    homepage = "https://forge.softwareheritage.org/source/swh-model/";
    license = licenses.gpl3Only;
  };
}
