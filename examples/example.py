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
# ## Inline images
#
# Set `display.image.renderer = "snacks"` and run this cell in a Kitty
# Graphics Protocol terminal (kitty / ghostty / wezterm) to see the
# rendered PNG below the cell. Without snacks.nvim or on an unsupported
# terminal, the cell falls back to its `text/plain` representation
# (the `<Figure size ...>` repr).
#
# `get_ipython().run_line_magic("matplotlib", "inline")` activates the
# matplotlib_inline backend so the kernel attaches `image/png` to the
# figure's MIME bundle — without it only `text/plain` is produced. The
# `%matplotlib inline` IPython magic is equivalent but is invalid Python
# syntax outside an IPython kernel, so this file uses the explicit form.

# %%
get_ipython().run_line_magic("matplotlib", "inline")  # noqa: F821
import matplotlib.pyplot as plt

xs = np.linspace(0, 2 * np.pi, 200)
fig, ax = plt.subplots(figsize=(6, 4), dpi=150)
ax.plot(xs, np.sin(xs), label="sin")
ax.plot(xs, np.cos(xs), label="cos")
ax.set_title("sin / cos")
ax.legend()

# %% [markdown]
# ## Errors render too
#
# Run the next cell to see the traceback rendered as virtual text.

# %%
1 / 0
