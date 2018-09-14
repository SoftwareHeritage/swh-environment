Software Heritage Python development environment
================================================

This repository contains the scaffolding to initialize and keep a local
development environment for the Software Heritage Python stack. In particular,
it contains pointers to the Git repositories of all Software Heritage Python
modules. The repositories are managed using [myrepos][1] (see the .mrconfig
file), and the `mr` command.

[1]: http://myrepos.branchable.com/

In Debian, the "mr" command is shipped in the "mr" package.

Once you have installed "mr", just use the following helper for both initial
code checkout and subsequent updates:

    cd swh-environment
    bin/update

Note that the first time you run `bin/update` it will add the
`swh-environment/.mrconfig` file to your `~/.mrtrust` (we use this to be able
to setup pre-commit hooks upon repository checkouts). See `MR(1)` for more
information about trusted `mr` repositories.

You can also checkout/update repositories by hand using `mr up`.

See `.mrconfig` for the actual list of repositories.


PYTHONPATH
----------

We use several Python modules, that should all be in the PYTHONPATH to be
found. To that extent, we provide in this repository a script to set the
PYTHONPATH variable to the correct value. You can use it as follows:

    . pythonpath.sh


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
