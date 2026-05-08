# %% [markdown]
# # jupyter.nvim demo (R)
#
# Open this file inside the devshell with `nvim examples/example.R`,
# then `:lua require('jupyter').start_kernel()` (which auto-selects the
# `ir` kernel) and step through the cells with
# `:lua require('jupyter').execute_cell()` (or `<localleader>jj` —
# the devshell wires up jupyter.nvim keymaps).

# %%
print("hello from the kernel")

# %%
sapply(1:5, sqrt)

# %%
set.seed(42)
data <- matrix(rnorm(12), nrow = 3, ncol = 4)
data

# %%
df <- as.data.frame(data)
colnames(df) <- LETTERS[1:4]
summary(df)

# %% [markdown]
# ## Inline images
#
# Base R graphics produce a PNG that IRkernel attaches to the output's
# MIME bundle. Set `display.image.renderer = "snacks"` and run this in a
# Kitty Graphics Protocol terminal (kitty / ghostty / wezterm) to see it
# inline; otherwise the cell falls back to text.

# %%
xs <- seq(0, 2 * pi, length.out = 200)
plot(xs, sin(xs), type = "l", col = "steelblue", main = "sin / cos", ylab = "")
lines(xs, cos(xs), col = "tomato")
legend("topright", legend = c("sin", "cos"), col = c("steelblue", "tomato"), lty = 1)

# %% [markdown]
# ## Errors render too
#
# Run the next cell to see the traceback rendered as virtual text.

# %%
stop("boom")
