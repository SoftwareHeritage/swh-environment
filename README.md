Software Heritage Python development environment
================================================

This repository contains the scaffolding to initialize and keep a local
development environment for the Software Heritage Python stack. In particular,
it contains pointers to the Git repositories of all Software Heritage Python
modules. The repositories are managed using [myrepos][1] (see the .mrconfig
file), and the `mr` command.

[1]: http://myrepos.branchable.com/

In Debian, the "mr" command is shipped in the "mr" package.

As our `.mrconfig` file contains "untrusted" checkout commands (specifically:
ensuring pre-commit hooks exist where needed), you need to add the path of your
`.mrconfig` file to your `~/.mrtrust` file:

    readlink -f .mrconfig >> ~/.mrtrust
 
You can then checkout the repositories using `mr up`.

See `.mrconfig` for the actual list of repositories.

For periodic updates after initial setup, you can use the `bin/update` helper:

    cd swh-environment
    bin/update


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
