; Capture Jupyter percent-format cell markers in Python source.
;
; Recognised marker forms:
;   # %%
;   # %% Some title
;   # %% [markdown]
;   # %% [markdown] Some title
;
; Lua-side code discriminates code vs markdown markers by matching the
; captured comment text against the [markdown] tag.

((comment) @cell.marker
 (#lua-match? @cell.marker "^#%s*%%%%"))

((comment) @cell.markdown
 (#lua-match? @cell.markdown "^#%s*%%%%%s*%[markdown%]"))
