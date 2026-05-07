# %% [markdown]
# # jupyter.nvim demo
#
# Open this file inside the devshell with `nvim examples/example.py`,
# then `:lua require('jupyter').start_kernel('python3')` and step through
# the cells with `:lua require('jupyter').execute_cell()` (or
# `<localleader>jj` — the devshell wires up jupyter.nvim keymaps).

# %%
print("hello from the kernel")

# %%
import math

[math.sqrt(n) for n in range(1, 6)]

# %%
import numpy as np

rng = np.random.default_rng(42)
data = rng.normal(size=(3, 4))
data

# %%
import pandas as pd

df = pd.DataFrame(data, columns=list("ABCD"))
df.describe()

# %% [markdown]
# ## Errors render too
#
# Run the next cell to see the traceback rendered as virtual text.

# %%
1 / 0
