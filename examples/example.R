# %% [markdown]
# # jupyter.nvim demo (R)
#
# Open this file inside the devshell with `nvim examples/example.R`,
# then `:JupyterStart` (which auto-selects the `ir` kernel) and step
# through the cells with `:JupyterExecute` (or `<localleader>jx` if
# default keymaps are enabled).

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
# ## Errors render too
#
# Run the next cell to see the traceback rendered as virtual text.

# %%
stop("boom")
