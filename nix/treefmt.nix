_: {
  projectRootFile = "flake.nix";

  programs = {
    nixfmt.enable = true;
    stylua.enable = true;
    ruff-check.enable = true;
    ruff-format.enable = true;
  };
}
