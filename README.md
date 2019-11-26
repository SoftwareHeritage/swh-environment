Software Heritage Python development environment
================================================

This repository contains the scaffolding to initialize and keep a local
development environment for the Software Heritage Python stack. In particular,
it contains pointers to the Git repositories of all Software Heritage Python
modules. The repositories are managed using [myrepos][1] (see the .mrconfig
file), and the `mr` command.

[1]: http://myrepos.branchable.com/

The provided mr config will also install a [pre-commit][2] hook in cloned
repositories, so the `pre-commit` tool must be available as well.

[2]: https://pre-commit.com/

In Debian, the "mr" command is shipped in the "mr" package.

Unfortunately, "pre-commit" itself is not available in Debian for now.

However, we strongly suggest you use a [virtualenv][3] to manage your SWH
development environment. You can create it using virtualenv, or you can
use a virtualenv wrapper tool like [virtualenvwrapper][4] or [pipenv][5] (or
any other similar tool). In Debian, both these tools are available as
"virtualenvwrapper" and "pipenv".

[3]: https://virtualenv.pypa.io/
[4]: https://virtualenvwrapper.readthedocs.io/
[5]: https://pipenv.readthedocs.io/

In the example below we are using virtualenv directly:

```lang=shell
git clone https://forge.softwareheritage.org/source/swh-environment.git
cd swh-environment
python3 -m venv .venv
. .venv/bin/activate
pip install pre-commit
```

then you can use the following helper for both initial code checkout and
subsequent updates:

```lang=shell
bin/update
```

Note that the first time you run `bin/update` it will add the
`swh-environment/.mrconfig` file to your `~/.mrtrust` (we use this to be able
to setup pre-commit hooks upon repository checkouts) and install "pre-commit"
as git precommit hook in each git repository. See `MR(1)` for more information
about trusted `mr` repositories.

You can also checkout/update repositories by hand using `mr up`.

See `.mrconfig` for the actual list of repositories.


Upgrade from makefile-based hooks
---------------------------------

Git pre commit hooks used to be makefile-based scripts. Running `mr update`
will automatically replace these by the `pre-commit` tool,


Initialize a new Python package repository
------------------------------------------

1. create the remote Git repository on the forge

2. add it to `.mrconfig` (e.g. using mr register)

3. mr update

   this will clone the (empty) repository locally

4. bin/init-py-repo REPO_NAME

   this will fill the repository with the template for SWH Python packages, and
   make an initial commit

5. cd REPO_NAME ; git push


Docker based test environment
-----------------------------

Check the README file in the docker/ directory.
