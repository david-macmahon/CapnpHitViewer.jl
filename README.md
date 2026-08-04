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
| `↑`/`↓`/`PgUp`/`PgDn`/`Home`/`End` | navigate hits (heatmap auto-reloads) |
| `o`                         | open file picker (browse mode)           |
| `r`                         | reload data for current hit              |
| `q` / `Esc`                 | quit                                     |

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
