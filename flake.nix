{
  description = "A Jupyter Notebook plugin for Neovim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      git-hooks,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # Python environment for Python kernel
        pythonKernelEnv = pkgs.python3.withPackages (ps: [
          ps.ipykernel
          ps.numpy
          ps.pandas
        ]);

        # Julia environment for Julia kernel
        juliaKernelEnv = pkgs.julia.withPackages [
          "IJulia"
        ];

        # R environment for R kernel
        rKernelEnv = pkgs.rWrapper.override {
          packages = with pkgs.rPackages; [
            IRkernel
          ];
        };

        # Create Jupyter kernels for Python, Julia, and R
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

        # Build the jupyter.nvim plugin
        jupyterNvimPlugin = pkgs.vimUtils.buildVimPlugin {
          pname = "jupyter-nvim";
          version = "0.1.0";
          src = ./.;
        };

        # Neovim with jupyter.nvim pre-installed and remote plugins registered
        neovimWithPlugin = pkgs.wrapNeovimUnstable pkgs.neovim-unwrapped {
          extraPython3Packages = ps: [
            ps.jupyter-client
          ];
          plugins = [
            {
              plugin = jupyterNvimPlugin;
            }
          ];
        };

        # Python environment with Jupyter server dependencies for testing
        pythonEnv = pkgs.python3.withPackages (
          ps: with ps; [
            jupyter
            jupyter-client
            ipykernel
            pynvim
          ]
        );

        # Pre-commit hooks configuration
        pre-commit-check = git-hooks.lib.${system}.run {
          src = ./.;
          hooks = {
            nixfmt-rfc-style.enable = true;
            nil.enable = true;
            statix.enable = true;
            lua-ls.enable = true;
            pyright = {
              enable = true;
              package = pkgs.basedpyright;
              entry = "${pkgs.basedpyright}/bin/basedpyright";
            };
            ruff.enable = true;
            ruff-format.enable = true;
          };
        };

      in
      {
        # Export the plugin package
        packages.default = jupyterNvimPlugin;

        # Expose pre-commit checks
        checks = {
          pre-commit = pre-commit-check;
        };

        # Development shell with test environment
        devShells.default = pkgs.mkShell {
          buildInputs = [
            neovimWithPlugin
            pythonEnv
            pkgs.jupyter
            pkgs.luajitPackages.vusted
            pkgs.lua-language-server
            pkgs.stylua
          ];

          shellHook = ''
            # Install pre-commit hooks
            ${pre-commit-check.shellHook}

            # Set up isolated Jupyter environment for testing
            # This prevents conflicts with the user's actual Jupyter installation
            export JUPYTER_TEST_DIR=$(mktemp -d -t jupyter-nvim-test.XXXXXXXXXX)

            export JUPYTER_CONFIG_DIR="$JUPYTER_TEST_DIR/jupyter/config"
            export JUPYTER_DATA_DIR="$JUPYTER_TEST_DIR/jupyter/data"
            export JUPYTER_RUNTIME_DIR="$JUPYTER_TEST_DIR/jupyter/runtime"
            export IPYTHONDIR="$JUPYTER_TEST_DIR/ipython"

            export JUPYTER_PATH=${kernels}

            export VUSTED_ARGS='--headless'

            mkdir -p "$JUPYTER_CONFIG_DIR" "$JUPYTER_DATA_DIR" "$JUPYTER_RUNTIME_DIR" "$IPYTHONDIR"

            # Clean up on shell exit
            cleanup() {
              rm -rf "$JUPYTER_TEST_DIR"
            }
            trap cleanup EXIT

            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  jupyter.nvim development environment"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "Available tools:"
            echo "  • nvim - Neovim editor"
            echo "  • python - Python with Jupyter libraries"
            echo "  • vusted - Lua test runner"
            echo "  • lua-language-server - Lua LSP"
            echo "  • stylua - Lua formatter"
            echo ""
            echo "Jupyter kernels installed:"
            echo "  • python3 - Python 3"
            echo "  • julia - Julia"
            echo "  • ir - R"
            echo ""
            echo "Jupyter test environment: $JUPYTER_TEST_DIR"
            echo "(will be cleaned up on shell exit)"
            echo ""
            echo "Run tests with:"
            echo "  vusted spec"
            echo ""
          '';
        };

        # Formatter
        formatter = pkgs.nixpkgs-fmt;
      }
    );
}
