# CapnpHitViewer.jl

A terminal UI for browsing seticore `.hits` files. Reads the capnp-encoded
hit records, lists them in a table, renders the filterbank data as a
heatmap, and shows per-hit metadata. Built with
[Tachikoma](https://github.com/JuliaTachikoma/Tachikoma.jl) and
[CairoMakie](https://github.com/MakieOrg/Makie.jl).

## Layout

```
┌───────────────────────────────────────────────────────────┐
│ title bar                                                 │
├──────────────────────┬────────────────────────────────────┤
│ hit table            │ heatmap (PixelImage)               │
│ (DataTable)          │ filterbank.data reshaped to        │
│                      │ numChannels × numTimesteps         │
│                      ├────────────────────────────────────┤
│                      │ hit metadata (Block)               │
├──────────────────────┴────────────────────────────────────┤
│ status bar / keybindings                                  │
└───────────────────────────────────────────────────────────┘
```

## Install

> **Note:** A Sixel- or Kitty-graphics-enabled terminal is strongly
> recommended. The heatmap is rendered as an in-band image; without
> graphics-protocol support it will not display. Popular multi-platform
> options:
> - [Ghostty](https://ghostty.org/)
> - [kitty](https://sw.kovidgoyal.net/kitty/)

```
julia -e 'import Pkg; Pkg.Apps.add(url="https://github.com/david-macmahon/CapnpHitViewer.jl")'
```

This installs the `hitsviewer` executable (see [Apps](https://julialang.github.io/Pkg.jl/v1/apps/)).
Make sure `~/.julia/bin` is on your `PATH`.

## Usage

Run with a hits file:

```
hitsviewer path/to/something.hits
```

Run without arguments to start in browse mode (file picker):

```
hitsviewer
```

### Keybindings (view mode)

| Key                         | Action                                   |
| --------------------------- | ---------------------------------------- |
| `↑`/`↓`/`PgUp`/`PgDn`/`Home`/`End` | navigate hits (cursor moves; heatmap loads per mode) |
| `Enter`                     | view selected hit (manual mode)          |
| `m`                         | toggle manual / auto mode                |
| `o`                         | open file picker (browse mode)           |
| `r`                         | reload data for current hit              |
| `q` / `Esc`                 | quit                                     |

In **auto mode** (default), navigating the table automatically loads each
hit's heatmap and metadata. In **manual mode**, navigation only moves the
selection cursor; press `Enter` to load the selected hit. The viewed row
is marked with `●` so it stays visible when the cursor has moved
elsewhere. Toggling back to auto mode loads the currently selected hit.

### Keybindings (browse mode)

| Key                         | Action                                   |
| --------------------------- | ---------------------------------------- |
| `↑`/`↓`/`PgUp`/`PgDn`/`Home`/`End` | navigate entries                    |
| `Enter`                     | descend into directory / select `.hits`  |
| `⌫`                         | parent directory                         |
| `h`                         | toggle hidden files                      |
| `r`                         | refresh listing                          |
| `Esc` / `q`                 | cancel (return to viewer, or quit)       |

## License

2-clause BSD. See [LICENSE](LICENSE).
