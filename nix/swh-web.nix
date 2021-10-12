{ pkgs, self, system }:
pkgs.python3Packages.buildPythonPackage rec {
  pname = "swh.web";
  version = "0.0.332";

  src = self.inputs.swh-web;

  # NOTE: tests are just a whole mess, need more investigation
  doCheck = false;

  propagatedBuildInputs = with pkgs.python3Packages; [
    # requirements.txt
    beautifulsoup4
    django
    django-cors-headers
    djangorestframework
    django-webpack-loader
    docutils
    htmlmin
    iso8601
    lxml
    prometheus_client
    pygments
    python_magic
    pyyaml
    requests
    sentry-sdk
    typing-extensions
    # NOTE: disabled because needs <2.9
    # psycopg2

    self.packages.${system}.django-js-reverse
    self.packages.${system}.psycopg28
    self.packages.${system}.pybadges
    self.packages.${system}.python-memcached

    # requirements-swh.txt
    self.packages.${system}.swh-auth
    self.packages.${system}.swh-core
    self.packages.${system}.swh-counters
    self.packages.${system}.swh-indexer
    self.packages.${system}.swh-model
    self.packages.${system}.swh-scheduler
    self.packages.${system}.swh-search
    self.packages.${system}.swh-storage
    self.packages.${system}.swh-vault
  ];

  # HACK: flakes don't include the `.git/` folder as part of the source, so
  #       setuptools fails because it can't identify the version this way, so we
  #       provide it explicitely.
  prePatch = ''
                substituteInPlace setup.py \
                  --replace 'setup_requires=["setuptools-scm", "tree-sitter==0.19.0"],' "" \
                  --replace "use_scm_version=True" 'version="${version}"'
              '';

  meta = with pkgs.lib; {
    homepage = "https://forge.softwareheritage.org/source/swh-web/";
    license = licenses.gpl3Only;
  };
}
