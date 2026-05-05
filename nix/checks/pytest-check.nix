{ inputs, pkgs, ... }:
let
  pythonEnv = pkgs.python3.withPackages (
    ps: with ps; [
      jupyter-client
      pynvim
      pytest
      pytest-mock
    ]
  );
in
pkgs.runCommand "pytest-check"
  {
    nativeBuildInputs = [ pythonEnv ];
    src = inputs.self;
  }
  ''
    cp -r $src/. .
    chmod -R u+w .
    export HOME=$TMPDIR
    # Default ``addopts`` already excludes ``tests/python/integration`` so
    # this run never touches a real kernel.
    pytest tests/python
    touch $out
  ''
