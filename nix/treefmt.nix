_: {
  projectRootFile = "flake.nix";

  # Cell-format example scripts may carry IPython magics
  # (`%matplotlib inline`) that aren't valid Python syntax. They are
  # opened as Jupyter buffers, not type-checked as modules.
  settings.global.excludes = [ "examples/*.py" ];

  programs = {
    nixfmt.enable = true;
    stylua.enable = true;
    ruff-check.enable = true;
    ruff-format.enable = true;
  };
}
