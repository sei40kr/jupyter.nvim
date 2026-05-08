{ inputs, pkgs, ... }:
let
  treefmtEval = inputs.treefmt.lib.evalModule pkgs ../treefmt.nix;
in
inputs.git-hooks.lib.${pkgs.stdenv.hostPlatform.system}.run {
  src = inputs.self;
  hooks = {
    nil.enable = true;
    statix.enable = true;
    lua-ls.enable = true;
    pyright = {
      enable = true;
      package = pkgs.basedpyright;
      entry = "${pkgs.basedpyright}/bin/basedpyright";
      # examples/ are opened as Jupyter-cell buffers, may carry IPython
      # magics (`%matplotlib inline`), and are exercised against a live
      # kernel — they are not part of the type-checked surface area.
      excludes = [ "^examples/" ];
    };
    convco.enable = true;
    treefmt = {
      enable = true;
      package = treefmtEval.config.build.wrapper;
    };
  };
}
