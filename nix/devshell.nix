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
        # Mirrors IJulia.installkernel's canonical argv. Avoid pointing
        # at IJulia's kernel.jl directly: under julia.withPackages it
        # lives in a content-addressed depot path (not under
        # share/julia/site/v<ver>), and modern kernel.jl only defines
        # run_kernel() without a top-level call. Also leave JULIA_PROJECT
        # to the wrapper — its depot project is what carries IJulia.
        argv = [
          "${juliaKernelEnv}/bin/julia"
          "-i"
          "--color=yes"
          "-e"
          "import IJulia; IJulia.run_kernel()"
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

  treesitterParsers = pkgs.vimPlugins.nvim-treesitter.withPlugins (p: [
    p.python
    p.julia
    p.r
  ]);

  neovimWithPlugin = pkgs.wrapNeovimUnstable pkgs.neovim-unwrapped (
    pkgs.neovimUtils.makeNeovimConfig {
      withPython3 = true;
      extraPython3Packages = ps: [ ps.jupyter-client ];
      plugins = [
        { plugin = jupyterNvimPlugin; }
        { plugin = treesitterParsers; }
        { plugin = pkgs.vimPlugins.blink-cmp; }
      ];
      customRC = ''
        lua << EOF
          -- jupyter.nvim's virtual LSP exposes completion + hover, so blink
          -- only needs its default LSP source — no plugin-specific provider.
          require("blink.cmp").setup({
            sources = { default = { "lsp", "buffer" } },
            keymap = { preset = "default" },
          })
        EOF
      '';
    }
  );

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
