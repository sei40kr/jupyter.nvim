{ inputs, pkgs, ... }:
let
  treesitterParsers = pkgs.vimPlugins.nvim-treesitter.withPlugins (p: [
    p.python
    p.julia
    p.r
  ]);

  # Wrap nvim with the python/julia/r parsers so jupyter.cell tests can
  # execute their Treesitter queries inside the sandbox.
  neovimWithParsers = pkgs.wrapNeovimUnstable pkgs.neovim-unwrapped {
    plugins = [ { plugin = treesitterParsers; } ];
  };
in
pkgs.runCommand "vusted-check"
  {
    nativeBuildInputs = [
      neovimWithParsers
      pkgs.luajitPackages.vusted
    ];
    src = inputs.self;
    env.VUSTED_ARGS = "--headless";
  }
  ''
    cp -r $src/. .
    chmod -R u+w .
    export HOME=$TMPDIR
    vusted tests/lua
    touch $out
  ''
