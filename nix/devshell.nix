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
      plugins = [
        { plugin = jupyterNvimPlugin; }
        { plugin = treesitterParsers; }
        { plugin = pkgs.vimPlugins.blink-cmp; }
        { plugin = pkgs.vimPlugins.which-key-nvim; }
      ];
      customRC = ''
        lua << EOF
          -- mapleader / maplocalleader must be set before any keymap
          -- that interpolates them is registered. The FileType autocmd
          -- below fires later, so setting them here is in time.
          vim.g.mapleader = " "
          vim.g.maplocalleader = ","

          -- jupyter.nvim's virtual LSP exposes completion + hover, so blink
          -- only needs its default LSP source — no plugin-specific provider.
          require("blink.cmp").setup({
            sources = { default = { "lsp", "buffer" } },
            keymap = { preset = "default" },
          })

          require("which-key").setup({})

          local KERNEL_BOUND_KEYS = {
            "<M-CR>",
            "<localleader>jj", "<localleader>ja",
            "<localleader>jc", "<localleader>jC",
            "<localleader>jr", "<localleader>jq",
            "<localleader>ji",
          }

          -- Editing verbs: always available on supported filetypes.
          vim.api.nvim_create_autocmd("FileType", {
            pattern = { "python", "julia", "r" },
            callback = function(ev)
              local jupyter = require("jupyter")
              local function map(lhs, rhs, desc)
                vim.keymap.set("n", lhs, rhs, {
                  buffer = ev.buf,
                  silent = true,
                  desc = desc,
                })
              end

              require("which-key").add({
                { "<localleader>j", group = "jupyter", buffer = ev.buf },
              })

              map("]j", jupyter.next_cell, "Next Cell")
              map("[j", jupyter.prev_cell, "Previous Cell")

              map("<localleader>jo", jupyter.insert_cell_below, "Insert Cell Below")
              map("<localleader>jO", jupyter.insert_cell_above, "Insert Cell Above")
              map("<localleader>jd", jupyter.delete_cell,       "Delete Cell")
              map("<localleader>jm", jupyter.merge_with_prev,   "Merge with Previous")
              map("<localleader>js", jupyter.split_at_cursor,   "Split Cell at Cursor")

              map("<localleader>jk", function() jupyter.start_kernel() end, "Start Kernel")
            end,
          })

          -- Kernel-bound verbs: live only between JupyterKernelReady and JupyterDeinitPre.
          vim.api.nvim_create_autocmd("User", {
            pattern = "JupyterKernelReady",
            callback = function(ev)
              local jupyter = require("jupyter")
              local function map(lhs, rhs, desc)
                vim.keymap.set("n", lhs, rhs, {
                  buffer = ev.data.bufnr,
                  silent = true,
                  desc = desc,
                })
              end

              map("<M-CR>",          jupyter.execute_and_advance, "Execute Cell and Advance")
              map("<localleader>jj", jupyter.execute_cell,        "Execute Cell")
              map("<localleader>ja", jupyter.execute_all,         "Execute All Cells")
              map("<localleader>jc", jupyter.clear_cell,          "Clear Cell Output")
              map("<localleader>jC", jupyter.clear_all_outputs,   "Clear All Outputs")
              map("<localleader>jr", jupyter.restart_kernel,      "Restart Kernel")
              map("<localleader>jq", jupyter.stop_kernel,         "Stop Kernel")
              map("<localleader>ji", jupyter.hover,               "Inspect Symbol")
            end,
          })

          vim.api.nvim_create_autocmd("User", {
            pattern = "JupyterDeinitPre",
            callback = function(ev)
              for _, lhs in ipairs(KERNEL_BOUND_KEYS) do
                pcall(vim.keymap.del, "n", lhs, { buffer = ev.data.bufnr })
              end
            end,
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
