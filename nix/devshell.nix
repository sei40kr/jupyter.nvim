{ inputs, pkgs, ... }:
let
  pre-commit-check = import ./checks/pre-commit-check.nix { inherit inputs pkgs; };
  jupyterNvimPlugin = import ./package.nix { inherit inputs pkgs; };

  pythonKernelEnv = pkgs.python3.withPackages (ps: [
    ps.ipykernel
    ps.numpy
    ps.pandas
  ]);

  juliaKernelEnv = pkgs.julia.withPackages [ "IJulia" ];

  rKernelEnv = pkgs.rWrapper.override {
    packages = with pkgs.rPackages; [ IRkernel ];
  };

  kernels = pkgs.jupyter-kernel.create {
    definitions = {
      python3 = {
        displayName = "Python 3";
        argv = [
          "${pythonKernelEnv}/bin/python"
          "-m"
          "ipykernel_launcher"
          "-f"
          "{connection_file}"
        ];
        language = "python";
        logo32 = null;
        logo64 = null;
      };
      julia = {
        displayName = "Julia";
        argv = [
          "${juliaKernelEnv}/bin/julia"
          "-i"
          "--color=yes"
          "--project=@."
          "${juliaKernelEnv}/share/julia/site/v${juliaKernelEnv.version}/IJulia/src/kernel.jl"
          "{connection_file}"
        ];
        language = "julia";
        logo32 = null;
        logo64 = null;
      };
      ir = {
        displayName = "R";
        argv = [
          "${rKernelEnv}/bin/R"
          "--slave"
          "-e"
          "IRkernel::main()"
          "--args"
          "{connection_file}"
        ];
        language = "R";
        logo32 = null;
        logo64 = null;
      };
    };
  };

  treesitterParsers = pkgs.vimPlugins.nvim-treesitter.withPlugins (p: [ p.python ]);

  neovimWithPlugin = pkgs.wrapNeovimUnstable pkgs.neovim-unwrapped {
    extraPython3Packages = ps: [ ps.jupyter-client ];
    plugins = [
      { plugin = jupyterNvimPlugin; }
      { plugin = treesitterParsers; }
    ];
  };

  pythonEnv = pkgs.python3.withPackages (
    ps: with ps; [
      jupyter
      jupyter-client
      ipykernel
      pynvim
      pytest
      pytest-mock
    ]
  );
in
pkgs.mkShell {
  packages = [
    neovimWithPlugin
    pythonEnv
    pkgs.jupyter
    pkgs.luajitPackages.vusted
    pkgs.lua-language-server
    pkgs.basedpyright
  ];

  env = {
    JUPYTER_PATH = "${kernels}";
    VUSTED_ARGS = "--headless";
  };

  shellHook = ''
    ${pre-commit-check.shellHook}

    # Set up an isolated Jupyter runtime so the dev shell does not touch the
    # user's real Jupyter installation.
    export JUPYTER_TEST_DIR=$(mktemp -d -t jupyter-nvim-test.XXXXXXXXXX)
    export JUPYTER_CONFIG_DIR="$JUPYTER_TEST_DIR/jupyter/config"
    export JUPYTER_DATA_DIR="$JUPYTER_TEST_DIR/jupyter/data"
    export JUPYTER_RUNTIME_DIR="$JUPYTER_TEST_DIR/jupyter/runtime"
    export IPYTHONDIR="$JUPYTER_TEST_DIR/ipython"

    mkdir -p "$JUPYTER_CONFIG_DIR" "$JUPYTER_DATA_DIR" "$JUPYTER_RUNTIME_DIR" "$IPYTHONDIR"

    cleanup() {
      rm -rf "$JUPYTER_TEST_DIR"
    }
    trap cleanup EXIT
  '';
}
