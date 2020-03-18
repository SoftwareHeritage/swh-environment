with import <nixpkgs> {};

let sources = import ../nix/sources.nix;
    pkgs = (import sources.nixpkgs {});
    ppackages = pkgs.python3Packages;
in stdenv.mkDerivation {
  name = "swhEnv";
  buildInputs = [
    # required packages for virtualenvwrapper and pip to work
    ppackages.virtualenvwrapper
    # runtime dependencies needed for the python modules pip will try
    # to install. In this particular environment the python modules
    # listed in the accumulated requirements.txt require the following
    # packages to be installed locally in order to compile any binary
    # extensions they may require.
    openssl
    libffi
    libzip
    stdenv
    zlib
    pkgs.docker
    pkgs.systemd.lib systemd ppackages.systemd
    # subvertpy needs this
    apr aprutil pkgs.subversion.dev
    # web (not enough)
    pkgs.libxml2
    python3Packages.lxml
    postgresql_11
    cassandra
    apacheKafka
  ];
  src = null;
  # Necessary environment variable to ease build within the pip environment
  PKG_CONFIG_PATH = "${pkgs.systemd.lib}/lib";
  SVN_PREFIX = "${pkgs.subversion.dev}";
  LD_LIBRARY_PATH = "${pkgs.postgresql_11.lib}/lib";
  # LC_ALL = "C.UTF-8";
  # LC_CTYPE = "C.UTF-8";
  # LANG = "C.UTF-8";
  shellHook =''
# set SOURCE_DATE_EPOCH so that we can use python wheels
SOURCE_DATE_EPOCH=$(date +%s)
source ${ppackages.virtualenvwrapper}/bin/virtualenvwrapper.sh
export ENV_NAME=nix-swh
export ENV_FOLDER=$HOME/.virtualenvs/$ENV_NAME/

install-or-update-env() {
  echo "($ENV_NAME) $ENV_FOLDER: Install tools..."
  pip install pytest tox pifpaf flake8 codespell pre-commit pdbpp ipython
  echo "($ENV_NAME) $ENV_FOLDER: Install pip swh packages..."
  pip install `./bin/pip-swh-packages --with-testing`
}

if [ ! -d $ENV_FOLDER ]; then
  echo "Creating virtualenv $ENV_NAME at $ENV_FOLDER"
  mkvirtualenv -p ${python3}/bin/python -a $SWH_ENVIRONMENT_HOME $ENV_NAME

  install-or-update-env
  echo "Creating virtualenv $ENV_NAME at $ENV_FOLDER. Done."
else
  echo "Connecting to virtualenv $ENV_NAME at $ENV_FOLDER"
  workon $ENV_NAME
fi

'';

}
