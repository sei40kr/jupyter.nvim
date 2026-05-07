{ pkgs, ... }:
let
  inherit (pkgs.lib) fileset;
  root = ../.;
in
pkgs.vimUtils.buildVimPlugin {
  pname = "jupyter-nvim";
  version = "0.1.0";

  # Only ship runtime artifacts. Development scaffolding (flake, nix
  # expressions, tests, scripts, CLAUDE.md, pyproject.toml, etc.) does
  # not belong in the installed plugin.
  src = fileset.toSource {
    inherit root;
    fileset = fileset.unions [
      (root + "/lua")
      (root + "/plugin")
      (root + "/queries")
      (root + "/rplugin")
      (root + "/README.md")
    ];
  };

  # Picked up automatically by `wrapNeovim` / `neovimUtils.makeNeovimConfig`
  # when this plugin is included in a user's plugin list. The Python remote
  # plugin under `rplugin/python3/` needs both at runtime.
  passthru.python3Dependencies =
    ps: with ps; [
      pynvim
      jupyter-client
    ];

  nvimRequireCheck = "jupyter";

  meta = {
    description = "A Jupyter Notebook plugin for Neovim";
    homepage = "https://github.com/sei40kr/jupyter.nvim";
    license = pkgs.lib.licenses.mit;
    platforms = pkgs.lib.platforms.all;
  };
}
