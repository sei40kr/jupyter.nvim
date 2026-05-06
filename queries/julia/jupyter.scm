; Capture Jupyter percent-format cell markers in Julia source.
;
; Recognised marker forms:
;   # %%
;   # %% Some title
;   # %% [markdown]
;   # %% [markdown] Some title
;
; tree-sitter-julia names single-line `#` comments `line_comment`.
; Lua-side code discriminates code vs markdown markers by matching the
; captured comment text against the [markdown] tag.

((line_comment) @cell.marker
 (#lua-match? @cell.marker "^#%s*%%%%"))

((line_comment) @cell.markdown
 (#lua-match? @cell.markdown "^#%s*%%%%%s*%[markdown%]"))
