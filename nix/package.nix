{ inputs, pkgs, ... }:
pkgs.vimUtils.buildVimPlugin {
  pname = "jupyter-nvim";
  version = "0.1.0";
  src = inputs.self;
}
