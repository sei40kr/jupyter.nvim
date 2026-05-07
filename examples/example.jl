# %% [markdown]
# # jupyter.nvim demo (Julia)
#
# Open this file inside the devshell with `nvim examples/example.jl`,
# then `:lua require('jupyter').start_kernel()` (which auto-selects the
# Julia kernel) and step through the cells with
# `:lua require('jupyter').execute_cell()` (or `<localleader>jj` —
# the devshell wires up jupyter.nvim keymaps).

# %%
println("hello from the kernel")

# %%
[sqrt(n) for n in 1:5]

# %%
using LinearAlgebra

A = reshape(1.0:12.0, 3, 4)
A * A'

# %%
using Statistics

xs = randn(1000)
(mean = mean(xs), std = std(xs))

# %% [markdown]
# ## Errors render too
#
# Run the next cell to see the traceback rendered as virtual text.

# %%
1 / 0  # returns Inf
sqrt(-1)  # throws DomainError
