# filepicker.jl ── filesystem navigation dialog for selecting a .hits file.
#
# The FilePicker is a modal mode (not a Tachikoma Modal widget) that
# replaces the main view when active. It shows the entries of the
# current directory in a SelectableList:
#   - directories first (with a trailing `/`), navigable with Enter,
#   - then files, with `.hits` files highlighted and selectable with
#     Enter to load them in the viewer.
#
# Keys:
#   ↑/↓/PgUp/PgDn/Home/End  navigate
#   Enter     descend into directory / select .hits file
#   Backspace go to parent directory
#   h         toggle hidden files (dotfiles)
#   r         refresh listing
#   Esc/q     cancel (return to viewer, or quit if no file loaded)

"""
    FilePicker

Modal filesystem browser state. Holds the absolute path of the
directory being viewed, the list of entries (computed via `readdir`),
and a `SelectableList` widget for rendering/navigation.

`on_select(path)` is called when the user picks a `.hits` file; the
caller wires this to load the file and switch modes. `on_cancel()` is
called when the user backs out (Esc/q); the caller decides whether to
return to the viewer or quit.
"""
mutable struct FilePicker
    cwd::String                        # absolute path of directory being listed
    show_hidden::Bool                  # whether to include dotfiles
    entries::Vector{String}            # sorted entry names in `cwd` (no path)
    is_dir::Vector{Bool}               # parallel to entries: is this entry a directory?
    list::SelectableList               # widget over display labels
    on_select::Function                # (abs_path::String) -> Nothing
    on_cancel::Function                # () -> Nothing
    status_msg::String                 # transient feedback (errors, hints)
end

"""
    FilePicker(; start_dir=pwd(), show_hidden=false, on_select, on_cancel)

Construct a FilePicker rooted at `start_dir` (defaults to the working
directory). `on_select` and `on_cancel` are callbacks invoked on
selection / cancellation.
"""
function FilePicker(; start_dir::AbstractString=pwd(),
                    show_hidden::Bool=false,
                    on_select::Function=_noop_select,
                    on_cancel::Function=_noop_cancel)
    p = FilePicker(abspath(start_dir), show_hidden, String[], Bool[],
                   SelectableList(String[]; selected=1),
                   on_select, on_cancel, "")
    _refresh!(p)
    p
end

_noop_select(::AbstractString) = nothing
_noop_cancel() = nothing

"Rebuild `entries` / `is_dir` / the SelectableList from `cwd`."
function _refresh!(p::FilePicker)
    if !isdir(p.cwd)
        p.entries = String[]
        p.is_dir = Bool[]
        p.list = SelectableList(String["(not a directory: $(p.cwd))"]; selected=1)
        p.status_msg = "not a directory: $(p.cwd)"
        return
    end
    names = try
        readdir(p.cwd)
    catch e
        p.entries = String[]
        p.is_dir = Bool[]
        p.list = SelectableList(String["(error reading directory: $(e))"]; selected=1)
        p.status_msg = "error reading $(p.cwd): $(e)"
        return
    end
    # Filter hidden (dotfiles) unless shown. ".." is always shown so the
    # user can navigate up via Enter on the explicit `..` entry too.
    filter!(n -> p.show_hidden || !startswith(n, '.'), names)
    # Sort: directories first, then files, alphabetical within each group
    is_dir_buf = Bool[isdir(joinpath(p.cwd, n)) for n in names]
    order = sortperm(collect(zip(.!is_dir_buf, names)))
    names = names[order]
    is_dir_buf = is_dir_buf[order]
    p.entries = names
    p.is_dir = is_dir_buf
    # Build display labels: directories get a trailing '/'.
    labels = String[n * (d ? "/" : "") for (n, d) in zip(names, is_dir_buf)]
    # Keep selection stable if possible, else reset to 1.
    sel = clamp(p.list.selected, 1, max(1, length(labels)))
    p.list = SelectableList(labels; selected=sel,
                            block=Block(title=_picker_title(p),
                                        border_style=tstyle(:border),
                                        title_style=tstyle(:title)),
                            highlight_style=tstyle(:accent, bold=true),
                            show_scrollbar=true)
    p.status_msg = isempty(names) ? "$(p.cwd) is empty" : ""
end

_picker_title(p::FilePicker) = "Browse: $(p.cwd)"

"Returns the absolute path of the entry at list position `idx`."
function _entry_path(p::FilePicker, idx::Int)::String
    1 ≤ idx ≤ length(p.entries) || return p.cwd
    abspath(joinpath(p.cwd, p.entries[idx]))
end

"Index of the `..` pseudo-entry, or 0 if not present."
_has_parent(p::FilePicker) = p.cwd != "/"

"Move the picker to the parent directory of `cwd`."
function _go_parent!(p::FilePicker)
    parent = dirname(p.cwd)
    isempty(parent) && return  # already at root
    p.cwd = abspath(parent)
    p.list.selected = 1
    _refresh!(p)
    # Try to land on the directory we came from so re-entering feels natural.
    came_from = basename(p.cwd)
    # (We came from `came_from`; we just navigated to its parent, so we
    # want to highlight `came_from/` if it's now in the listing.)
    idx = findfirst(==(came_from), p.entries)
    if idx !== nothing
        p.list.selected = idx
    end
end

"Move the picker into the directory at list position `idx`."
function _enter_dir!(p::FilePicker, idx::Int)
    target = _entry_path(p, idx)
    if !isdir(target)
        p.status_msg = "not a directory: $target"
        return
    end
    p.cwd = target
    p.list.selected = 1
    _refresh!(p)
end

"Handle a key event while the picker is active. Returns nothing."
function _picker_handle_key!(p::FilePicker, evt::KeyEvent)
    # Backspace: go up (matches many file managers).
    if evt.key == :backspace
        _go_parent!(p)
        return
    end
    if evt.key == :char
        evt.char == 'h' && begin
            p.show_hidden = !p.show_hidden
            _refresh!(p)
            return
        end
        evt.char == 'r' && begin
            _refresh!(p)
            return
        end
        evt.char == 'q' && begin
            p.on_cancel()
            return
        end
    end
    if evt.key == :escape
        p.on_cancel()
        return
    end
    if evt.key == :enter
        idx = p.list.selected
        if idx == 0 || idx > length(p.entries)
            return
        end
        if p.is_dir[idx]
            _enter_dir!(p, idx)
        else
            path = _entry_path(p, idx)
            if endswith(path, ".hits")
                p.on_select(path)
            else
                p.status_msg = "not a .hits file: $(p.entries[idx])"
            end
        end
        return
    end
    # Default: delegate to the list for navigation.
    handle_key!(p.list, evt)
end

"Handle a mouse event while the picker is active."
function _picker_handle_mouse!(p::FilePicker, evt::MouseEvent)
    # Double-click semantics: a left click selects; a second click on
    # the same row enters/selects. Tachikoma's MouseEvent doesn't carry
    # a click count, so we treat a press as "select + try to act":
    #   - on a directory: enter it
    #   - on a .hits file: select it
    # Single-click-to-select-then-Enter is the safer default though, so
    # for now we just delegate to the list for selection and let the
    # user press Enter to act.
    handle_mouse!(p.list, evt)
end

"Render the picker full-screen (header + list + footer)."
function _render_picker(p::FilePicker, f::Frame)
    buf = f.buffer
    rows = split_layout(Layout(Vertical, [Fixed(1), Fill(), Fixed(1)]), f.area)
    length(rows) < 3 && return
    header_area = rows[1]
    body_area   = rows[2]
    footer_area = rows[3]

    # ── Header ──
    title = "CapnpHitViewer — file picker"
    hx = header_area.x + max(0, (header_area.width - length(title)) ÷ 2)
    set_string!(buf, hx, header_area.y, title, tstyle(:title, bold=true))
    # Show hidden-state indicator on the left.
    hidden_tag = p.show_hidden ? "showing hidden" : "hiding hidden"
    set_string!(buf, header_area.x, header_area.y, hidden_tag, tstyle(:text_dim))

    # ── Body: the SelectableList ──
    p.list.block = Block(title=_picker_title(p),
                         border_style=tstyle(:border),
                         title_style=tstyle(:title))
    p.list.tick = 0  # no animation needed for the picker
    render(p.list, body_area, buf)

    # ── Footer ──
    status = p.status_msg
    if isempty(status)
        n = length(p.entries)
        nd = count(identity, p.is_dir)
        nf = n - nd
        status = "$nd dirs, $nf files"
    end
    render(StatusBar(
        left=[Span("  [↑↓]nav [Enter]open [⌫]up [h]hidden [r]refresh ",
                    tstyle(:text_dim))],
        right=[Span(status, tstyle(:accent, bold=true))],
    ), footer_area, buf)
end
