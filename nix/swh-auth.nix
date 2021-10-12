{ pkgs, self, system }:
pkgs.python3Packages.buildPythonPackage rec {
  pname = "swh.auth";
  version = "0.6.1";

  src = self.inputs.swh-auth;

  # NOTE: tests are just a whole mess, need more investigation
  doCheck = false;

  propagatedBuildInputs = with pkgs.python3Packages; [
    # requirements.txt
    click
    pyyaml

    self.packages.${system}.python-keycloak

    # requirements-django.txt
    django
    djangorestframework
    sentry-sdk

    # requirements-swh.txt
    self.packages.${system}.swh-core
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
    homepage = "https://forge.softwareheritage.org/source/swh-auth/";
    license = licenses.gpl3Only;
  };
}
