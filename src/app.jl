# app.jl ── Tachikoma TUI for browsing seticore .hits files.
#
# Layout (view mode):
#   ┌───────────────────────────────────────────────────────────┐
#   │ title bar                                                  │
#   ├──────────────────────┬────────────────────────────────────┤
#   │ hit table            │ heatmap (PixelImage)               │
#   │ (DataTable)          │ filterbank.data reshaped to        │
#   │                      │ numChannels × numTimesteps         │
#   │                      ├────────────────────────────────────┤
#   │                      │ hit metadata (Block)               │
#   ├──────────────────────┴────────────────────────────────────┤
#   │ status bar / keybindings                                   │
#   └───────────────────────────────────────────────────────────┘
#
# Browse mode (file picker) replaces the body with a directory listing
# so the user can navigate the filesystem and pick a .hits file.
#
# Keys (view mode):
#   ↑/↓/PgUp/PgDn/Home/End  navigate hits
#   Enter  view selected hit (manual mode) / no-op (auto mode)
#   m      toggle manual mode (auto-view on nav vs. view-on-Enter)
#   o     open file picker (browse mode)
#   r     reload data for current hit (re-reads the capnp message)
#   q/Esc quit
#
# Keys (browse mode):
#   ↑/↓/PgUp/PgDn/Home/End  navigate entries
#   Enter  descend into directory / select .hits file
#   ⌫      parent directory
#   h      toggle hidden files
#   r      refresh listing
#   Esc/q  cancel (return to viewer, or quit if no file loaded)

@kwdef mutable struct HitViewerModel <: Model
    quit::Bool = false
    tick::Int = 0
    mode::Symbol = :view               # :view or :browse
    path::String = ""                  # hits file path (empty if none loaded yet)
    hits::Vector{HitMetadata} = HitMetadata[]
    # DataTable over `hits`
    table::DataTable = DataTable(DataColumn[])
    # Cached heatmap data for the currently *viewed* hit (the one rendered
    # in the heatmap + metadata panel). In auto mode this tracks the
    # table selection; in manual mode it only changes on Enter.
    current_idx::Int = 0               # 1-based index into hits; 0 = none
    heatmap::Union{Nothing,Matrix{Float32}} = nothing
    # Manual mode: when true, navigating the table does NOT auto-load the
    # heatmap. The viewer only loads a hit when the user presses Enter.
    manual_mode::Bool = false
    status_msg::String = ""
    picker::Union{FilePicker,Nothing} = nothing
    # CairoMakie render pipeline (reused across frames; surf is the
    # cache key — nuking it forces a re-render on the next frame).
    fig::Figure = Figure(size=(0,0))
    surf::CairoSurfaceImage{RGB24} = CairoImageSurface(RGB24[;;])
    screen::CairoMakie.Screen = CairoMakie.Screen()
    img::PixelImage = PixelImage(0,0)
end

should_quit(m::HitViewerModel) = m.quit

# Marker drawn in the table's left margin for the hit currently shown in
# the heatmap/metadata panel. Distinct from the selection marker (▸) so
# the two highlights don't clash when they differ (manual mode).
const VIEWED_MARKER = '●'

# ── Build the DataTable from the hits vector ─────────────────────────

function _build_table(hits::Vector{HitMetadata})::DataTable
    n = length(hits)
    idx       = collect(Any, 1:n)
    freq      = collect(Any, [round(h.frequency; digits=6) for h in hits])
    snr       = collect(Any, [round(Float64(h.snr); digits=2) for h in hits])
    drift     = collect(Any, [round(h.driftRate; digits=6) for h in hits])
    steps     = collect(Any, [Int(h.driftSteps) for h in hits])
    beam      = collect(Any, [Int(h.beam) for h in hits])
    coarse    = collect(Any, [Int(h.coarseChannel) for h in hits])
    nch       = collect(Any, [Int(h.numChannels) for h in hits])
    ntsteps   = collect(Any, [Int(h.fbNumTimesteps) for h in hits])
    src       = collect(Any, [h.sourceName for h in hits])

    DataTable([
        DataColumn("#",         idx;     align=col_right),
        DataColumn("Frequency", freq;    align=col_right),
        DataColumn("SNR",       snr;     align=col_right),
        DataColumn("DriftRate", drift;   align=col_right),
        DataColumn("Steps",     steps;   align=col_right),
        DataColumn("Beam",      beam;    align=col_right),
        DataColumn("CoarseCh",  coarse;  align=col_right),
        DataColumn("NumChans",  nch;     align=col_right),
        DataColumn("NumSteps",  ntsteps; align=col_right),
        DataColumn("Source",    src),
    ], selected=1, show_scrollbar=true)
end

# ── CairoMakie → Tachikoma pixel bridge ───────────────────────────────
#
# Cairo renders into a Matrix{RGB24} in place (via CairoImageSurface's
# cairo_image_surface_create_for_data). This helper converts each RGB24
# (packed as 0xffRRGGBB in Cairo's FORMAT_RGB24) to a Tachikoma ColorRGBA
# for the PixelImage buffer that sixel/kitty/braille rendering reads from.
# Alpha is 0xff (opaque) for FORMAT_RGB24, so kitty uses efficient RGB mode.

function colorrgba(rgb24::RGB24)
    a, r, g, b = (rgb24.color .>> (24, 16, 8, 0)) .% UInt8
    ColorRGBA(r, g, b, a)
end

# ── Heatmap loading / caching ────────────────────────────────────────

function _load_heatmap!(m::HitViewerModel, idx::Int=m.table.selected)
    if idx == 0 || idx > length(m.hits)
        m.heatmap = nothing
        m.current_idx = 0
        return
    end
    if idx == m.current_idx && m.heatmap !== nothing
        return  # already cached
    end
    hit = m.hits[idx]
    try
        data = load_hit_data(m.path, hit)
        m.heatmap = data
        m.current_idx = idx
        # Nuke the Cairo surface to force a re-render on the next frame
        # (data changed, even if the area size didn't).
        m.surf = CairoImageSurface(RGB24[;;])
        m.status_msg = "loaded hit $idx: $(size(data,1)) channels × $(size(data,2)) timesteps"
    catch e
        m.heatmap = nothing
        m.current_idx = 0
        m.status_msg = "error loading hit $idx: $(typeof(e).__name__) $(e)"
    end
end

# ── Event handling ───────────────────────────────────────────────────

function update!(m::HitViewerModel, evt::KeyEvent)
    if m.mode == :browse && m.picker !== nothing
        _picker_handle_key!(m.picker, evt)
        return
    end
    _update_view!(m, evt)
end

function _update_view!(m::HitViewerModel, evt::KeyEvent)
    # Delegate to the table for navigation/sort/etc. when the detail view
    # is open — it intercepts all keys.
    if m.table.show_detail
        handle_key!(m.table, evt)
        return
    end

    if evt.key == :char
        evt.char == 'q' && (m.quit = true; return)
        evt.char == 'r' && begin
            # Force reload of the currently viewed hit.
            m.current_idx = 0
            _load_heatmap!(m, m.table.selected)
            return
        end
        evt.char == 'o' && begin
            _open_picker!(m)
            return
        end
        evt.char == 'm' && begin
            m.manual_mode = !m.manual_mode
            if m.manual_mode
                m.status_msg = "manual mode: press Enter to view selected hit"
            else
                m.status_msg = "auto mode: heatmap follows selection"
                # Loading the selected hit brings the viewed hit in sync
                # with the cursor when leaving manual mode.
                if m.table.selected != m.current_idx
                    _load_heatmap!(m, m.table.selected)
                end
            end
            return
        end
    end
    evt.key == :escape && (m.quit = true; return)

    # Enter loads the selected hit in manual mode (no-op in auto mode,
    # where navigation already loads it).
    if evt.key == :enter && m.manual_mode
        _load_heatmap!(m, m.table.selected)
        return
    end

    # Let the table handle navigation; in auto mode, reload the heatmap
    # when the selection changes. In manual mode, navigation only moves
    # the selection cursor — the viewed hit is unchanged until Enter.
    prev = m.table.selected
    handled = handle_key!(m.table, evt)
    if handled && !m.manual_mode && m.table.selected != prev
        _load_heatmap!(m, m.table.selected)
    end
end

function update!(m::HitViewerModel, evt::MouseEvent)
    if m.mode == :browse && m.picker !== nothing
        _picker_handle_mouse!(m.picker, evt)
        return
    end
    # Forward to the table for click-to-select / scroll. In auto mode,
    # clicking a row also loads its heatmap; in manual mode, the click
    # only moves the selection (Enter is required to view).
    prev = m.table.selected
    handle_mouse!(m.table, evt)
    if !m.manual_mode && m.table.selected != prev
        _load_heatmap!(m, m.table.selected)
    end
end

# ── View ─────────────────────────────────────────────────────────────

function view(m::HitViewerModel, f::Frame)
    m.tick += 1
    if m.mode == :browse && m.picker !== nothing
        _render_picker(m.picker, f)
        return
    end
    _render_view(m, f)
end

function _render_view(m::HitViewerModel, f::Frame)
    buf = f.buffer

    # Layout: 1 (title) / fill / 1 (status)
    rows = split_layout(Layout(Vertical, [Fixed(1), Fill(), Fixed(1)]), f.area)
    length(rows) < 3 && return
    header_area = rows[1]
    body_area   = rows[2]
    footer_area = rows[3]

    # ── Header ──
    title = isempty(m.path) ? "CapnpHitViewer" : "CapnpHitViewer — $(basename(m.path))"
    hx = header_area.x + max(0, (header_area.width - length(title)) ÷ 2)
    set_string!(buf, hx, header_area.y, title, tstyle(:title, bold=true))
    nhits = length(m.hits)
    sel = m.table.selected
    set_string!(buf, header_area.x, header_area.y,
                "$nhits hits", tstyle(:text_dim))
    if nhits > 0 && sel > 0
        info = "  selected $sel/$(nhits)"
        set_string!(buf, header_area.x + length("$nhits hits"), header_area.y,
                    info, tstyle(:accent, bold=true))
    end
    if m.manual_mode
        tag = " MANUAL"
        set_string!(buf, right(header_area) - length(tag) + 1, header_area.y,
                    tag, tstyle(:warning, bold=true))
    end

    # ── Body: left = table, right = heatmap + metadata ──
    # Vertical separator column eats 1 char.  Table gets 60%, right col fill.
    body_cols = split_layout(Layout(Horizontal, [Percent(60), Fixed(1), Fill()]), body_area)
    length(body_cols) < 3 && return
    table_area = body_cols[1]
    sep_area   = body_cols[2]
    right_area = body_cols[3]

    # Render the table. In manual mode, tint the currently-viewed row
    # (the one shown in the heatmap/metadata) so it stands out from the
    # selection cursor. When the viewed row is also the selected row the
    # DataTable's selected_style wins, so there's no clash.
    m.table.block = Block(title="Signals",
                          border_style=tstyle(:border),
                          title_style=tstyle(:title))
    m.table.tick = m.tick
    _apply_viewed_row_style!(m)
    render(m.table, table_area, buf)
    _draw_viewed_marker!(m, buf)

    # Render the separator
    for ry in sep_area.y:bottom(sep_area)
        set_char!(buf, sep_area.x, ry, BOX_PLAIN.v, tstyle(:border, dim=true))
    end

    # Split the right column into heatmap (fill) + metadata panel (fixed).
    # The 1-cell gap lets the heatmap's Makie-rendered border and the
    # metadata Block's border sit side by side without touching.
    # Fixed(17) fits all 15 metadata rows + 2 border rows.
    right_rows = split_layout(Layout(Vertical, [Fill(), Fixed(1), Fixed(17)]),
                              right_area)
    if length(right_rows) ≥ 3
        heat_area = right_rows[1]
        meta_area = right_rows[3]
    else
        heat_area = right_area
        meta_area = Rect(0,0,0,0)
    end

    # Render the heatmap
    _render_heatmap(m, heat_area, f)

    # Render the metadata panel
    _render_metadata(m, meta_area, buf)

    # ── Footer ──
    _render_footer(m, footer_area, buf)
end

# ── Viewed-hit table highlight ────────────────────────────────────────
#
# In manual mode the hit shown in the heatmap/metadata panel (current_idx)
# can differ from the table's selection cursor. We mark that row in two
# ways so it's distinguishable from the selection highlight (accent ▸):
#   1. row_styles tint — the row's text gets the theme's secondary color
#      (handled inside DataTable::render, which ignores row_styles for
#      the selected row, so no clash when viewed == selected).
#   2. left-margin marker — VIEWED_MARKER (●) drawn in the secondary
#      color at the row's left edge (only when viewed != selected; the
#      selected row already draws its own ▸ there).

"Ensure `m.table.row_styles` is the right length and tint the viewed row."
function _apply_viewed_row_style!(m::HitViewerModel)
    n = length(m.hits)
    dt = m.table
    if length(dt.row_styles) != n
        resize!(dt.row_styles, n)
    end
    fill!(dt.row_styles, tstyle(:text))
    v = m.current_idx
    if m.manual_mode && v > 0 && v <= n
        dt.row_styles[v] = tstyle(:secondary)
    end
end

"Draw the viewed-hit marker in the table's left margin (manual mode only)."
function _draw_viewed_marker!(m::HitViewerModel, buf::Buffer)
    m.manual_mode || return
    v = m.current_idx
    (v == 0 || v > length(m.hits)) && return
    dt = m.table
    # Don't double-mark: the selected row already shows ▸.
    dt.selected == v && return
    # Find the viewed row's display position in the current sort order.
    pos = findfirst(==(v), dt.sort_perm)
    pos === nothing && return
    vis_h = dt.last_content_area.height - 2  # header + separator
    vi = pos - dt.offset
    (vi < 1 || vi > vis_h) && return  # scrolled out of view
    y = dt.last_content_area.y + 1 + vi
    set_char!(buf, dt.last_content_area.x, y, VIEWED_MARKER,
              tstyle(:secondary, bold=true))
end

function _render_heatmap(m::HitViewerModel, area::Rect, f::Frame)
    buf = f.buffer

    # No surrounding Block: Makie renders its own title/axes/border inside
    # the image, so give it the full area (N2=b). Just clear the border
    # cells with the background so no stale text leaks through.
    inner = area

    # If no hit is loaded, just clear interior with a hint.
    if m.heatmap === nothing
        msg = if m.current_idx == 0 && m.table.selected == 0
            "no hit selected"
        elseif m.manual_mode
            "press Enter to view the selected hit"
        else
            "select a hit to load its filterbank.data"
        end
        mx = inner.x + max(0, (inner.width - length(msg)) ÷ 2)
        my = inner.y + max(0, inner.height ÷ 2)
        set_string!(buf, mx, my, msg, tstyle(:text_dim, dim=true))
        return
    end

    _draw_pixel_heatmap(m, m.heatmap, inner, f)
end

# ── Hit metadata panel ────────────────────────────────────────────────
#
# Renders a bordered Block below the heatmap showing key/value pairs for
# the currently viewed hit (the one in the heatmap; in auto mode this is
# the selected hit, in manual mode it's the last hit loaded with Enter).
# The Block gives it a visual frame consistent with the table on the left.

function _render_metadata(m::HitViewerModel, area::Rect, buf::Buffer)
    (area.width < 2 || area.height < 2) && return
    idx = m.current_idx
    title = (idx == 0 || idx > length(m.hits)) ? "Metadata" : "Hit $idx metadata"
    block = Block(title=title,
                  border_style=tstyle(:border),
                  title_style=tstyle(:title))
    inner = render(block, area, buf)
    (inner.width < 2 || inner.height < 1) && return

    if idx == 0 || idx > length(m.hits)
        msg = "no hit selected"
        mx = inner.x + max(0, (inner.width - length(msg)) ÷ 2)
        my = inner.y + max(0, inner.height ÷ 2)
        set_string!(buf, mx, my, msg, tstyle(:text_dim, dim=true))
        return
    end

    hit = m.hits[idx]
    # Two-column key/value rows. Label style dim, value style normal/bold.
    label_w = 16
    rows = [
        ("Source",        hit.sourceName),
        ("Frequency",     string(round(hit.frequency; digits=6), " MHz")),
        ("SNR",           string(round(Float64(hit.snr); digits=2))),
        ("DriftRate",     string(round(hit.driftRate; digits=6), " Hz/s")),
        ("DriftSteps",    string(Int(hit.driftSteps))),
        ("Beam",          string(Int(hit.beam))),
        ("CoarseChannel", string(Int(hit.coarseChannel))),
        ("NumChannels",   string(Int(hit.numChannels))),
        ("NumTimesteps",  string(Int(hit.numTimesteps))),
        ("fch1",          string(round(hit.fch1; digits=6), " MHz")),
        ("foff",          string(round(hit.foff * 1e6; digits=3), " Hz")),
        ("tsamp",         string(round(hit.tsamp; digits=6), " s")),
        ("tstart",        string(round(hit.tstart; digits=6))),
        ("RA",            _ra_sexagesimal(hit.ra)),
        ("Dec",           _dec_sexagesimal(hit.dec)),
    ]

    y = inner.y
    for (k, v) in rows
        y > bottom(inner) && break
        set_string!(buf, inner.x, y, k, tstyle(:text_dim))
        set_string!(buf, inner.x + label_w, y, v, tstyle(:text, bold=true);
                    max_x=right(inner))
        y += 1
    end
end

# Format RA (in hours) as sexagesimal HHhMMmSS.SSSs, rounding fractional
# seconds to 3 places.
function _ra_sexagesimal(ra::Real)::String
    r = mod(ra, 24.0)
    h = floor(Int, r)
    r = (r - h) * 60.0
    m = floor(Int, r)
    s = (r - m) * 60.0
    @sprintf("%dh%02dm%06.3fs", h, m, s)
end

# Format Dec (in degrees) as sexagesimal ±DD°MMmSS.SSSs, rounding fractional
# seconds to 3 places. The leading sign preserves the hemisphere.
function _dec_sexagesimal(dec::Real)::String
    sign = dec < 0 ? -1 : 1
    d = abs(dec)
    deg = floor(Int, d)
    d = (d - deg) * 60.0
    m = floor(Int, d)
    s = (d - m) * 60.0
    @sprintf("%s%d°%02dm%06.3fs", sign < 0 ? "-" : "+", deg, m, s)
end

# Render the heatmap via CairoMakie directly into a Matrix{RGB24}
# (Cairo writes into the Julia-owned matrix in place via
# cairo_image_surface_create_for_data), then copy to a Tachikoma
# PixelImage for sixel/kitty/braille output. No PNG round-trip.
#
# Caching: `m.surf.data` is the cache key. If its size matches the
# requested area's pixel dims, the previous render is reused (cache hit
# → just re-emit the PixelImage). Cache is invalidated by resetting
# `m.surf = CairoImageSurface(RGB24[;;])` whenever the underlying data
# changes (hit selection, file load).
function _draw_pixel_heatmap(m::HitViewerModel, data::Matrix{Float32}, area::Rect, f::Frame)
    (area.width < 2 || area.height < 2) && return

    sz = Tachikoma._pixelimage_pixel_dims(area.width, area.height)
    # Cache hit: size unchanged and surface still valid → reuse m.img.
    if sz != size(m.surf.data)
        # Cache miss: rebuild figure, surface, and pixel image.
        nch, nt = size(data)
        hitidx = m.current_idx
        hit = (hitidx > 0 && hitidx ≤ length(m.hits)) ? m.hits[hitidx] : nothing

        # Title/subtitle with hit metadata (N3=frequency/time).
        title = hit === nothing ? "Heatmap" :
                "$(hit.sourceName) │ Hit $(hitidx)"
        subtitle = hit === nothing ? "" :
                   "DR $(round(hit.driftRate; digits=3)) │ SNR $(round(Float64(hit.snr); digits=2)) │ Freq $(round(hit.frequency; digits=3)) Hz"

        # Pass data (nch × nt) directly to heatmap! — no permutedims, no
        # explicit x/y vectors. Makie puts size(z,1) on x (channels→) and
        # size(z,2) on y (timesteps, yreversed → time↓). Ticks default to
        # channel/timestep indices; we relabel them in physical units
        # (MHz, s) via tick formatters so the underlying bin geometry
        # stays on the integer grid (no floating-point edge computation
        # for tightly-spaced channel frequencies).
        m.fig = Figure(; size=sz)
        ax = Axis(m.fig[1,1]; yreversed=true,
            title=title, subtitle=subtitle,
            xlabel="Frequency Offset (Hz)", ylabel="Time (s)")
        heatmap!(ax, data; colormap=:viridis)

        # Relabel ticks in physical units (N3=frequency/time) while keeping
        # the integer-grid bin layout. For the x-axis, set explicit ticks
        # at round Hz offsets (including 0) so the axis reads cleanly.
        if hit !== nothing
            fch1, foff, tsamp = hit.fch1, hit.foff, hit.tsamp
            sigfreq_mhz = hit.frequency  # signal.frequency is in MHz (same as fch1/foff)
            hz_offset(i) = (fch1 + (i - 1) * foff - sigfreq_mhz) * 1e6
            hz_lo, hz_hi = hz_offset(1), hz_offset(nch)
            # Pick a nice step (1, 2, 5, 10, 20, 50, ...) giving ~5-10 ticks.
            R = hz_hi - hz_lo
            nice = (1, 2, 5, 10, 20, 50, 100, 200, 500, 1000,
                    2000, 5000, 10_000, 20_000, 50_000, 100_000)
            step = nice[end]
            for s in nice
                if R / s ≤ 10
                    step = s
                    break
                end
            end
            # Round Hz values in [hz_lo, hz_hi] at multiples of step, incl 0.
            tick_hz = Int[]
            t = 0
            while t ≥ round(Int, floor(hz_lo / step) * step)
                pushfirst!(tick_hz, t)
                t -= step
            end
            t = step
            while t ≤ round(Int, ceil(hz_hi / step) * step)
                push!(tick_hz, t)
                t += step
            end
            # Map each round Hz value back to channel-index position.
            positions = Float64[]
            labels = String[]
            for hz in tick_hz
                i = (hz / 1e6 + sigfreq_mhz - fch1) / foff + 1
                if 1 ≤ i ≤ nch
                    push!(positions, i)
                    push!(labels, string(hz))
                end
            end
            ax.xticks = (positions, labels)
            ax.ytickformat = ys -> [string(round((y - 1) * tsamp;
                                                digits=3)) for y in ys]
        end

        # Draw into the in-place RGB24 matrix.
        m.surf = CairoImageSurface(Matrix{RGB24}(undef, sz))
        conf = Makie.merge_screen_config(CairoMakie.ScreenConfig,
                                         Dict(:px_per_unit => 1))
        m.screen = CairoMakie.Screen(m.fig.scene, conf, m.surf)
        CairoMakie.cairo_draw(m.screen, m.fig.scene)

        # Copy RGB24 → ColorRGBA + transpose (Cairo is (w,h), Tachikoma is (h,w)).
        m.img = PixelImage(area.width, area.height)
        map!(colorrgba, m.img.pixels, PermutedDimsArray(m.surf.data, (2,1)))
    end

    # Emit via the detected graphics protocol (sixel/kitty/braille).
    render(m.img, area, f; tick=m.tick)
end

# ── Status bar ───────────────────────────────────────────────────────

function _render_footer(m::HitViewerModel, area::Rect, buf::Buffer)
    status = m.status_msg
    if isempty(status)
        status = isempty(m.hits) ? "no hits loaded" : "ready"
    end
    keys = m.manual_mode ?
        "  [↑↓]navigate [Enter]view [m]auto [o]open [r]reload [q/Esc]quit " :
        "  [↑↓]navigate [m]manual [o]open file [r]reload [q/Esc]quit "
    render(StatusBar(
        left=[Span(keys, tstyle(:text_dim))],
        right=[Span(status, tstyle(:accent, bold=true))],
    ), area, buf)
end

# ── Picker open / close / file loading ───────────────────────────────

"Open the file picker, rooted at `start_dir` (defaults to the directory
of the current file if one is loaded, else the working directory)."
function _open_picker!(m::HitViewerModel; start_dir::Union{Nothing,AbstractString}=nothing)
    dir = if start_dir !== nothing
        start_dir
    elseif !isempty(m.path) && isfile(m.path)
        dirname(m.path)
    else
        pwd()
    end
    m.picker = FilePicker(;
        start_dir=dir,
        on_select=path -> _on_picker_select!(m, path),
        on_cancel=() -> _on_picker_cancel!(m),
    )
    m.mode = :browse
end

"Close the picker and return to view mode. If no file is loaded, quit."
function _close_picker!(m::HitViewerModel)
    m.picker = nothing
    m.mode = :view
    if isempty(m.path)
        # Nothing to view — quit the app.
        m.quit = true
    end
end

"Callback invoked by the picker when the user selects a .hits file."
function _on_picker_select!(m::HitViewerModel, path::AbstractString)
    if _load_file!(m, path)
        m.picker = nothing
        m.mode = :view
    end
end

"Callback invoked by the picker on cancel (Esc/q)."
function _on_picker_cancel!(m::HitViewerModel)
    _close_picker!(m)
end

"Load a .hits file: scan metadata, rebuild the table, reset heatmap
state. Returns true on success, false on error (with status_msg set)."
function _load_file!(m::HitViewerModel, path::AbstractString)::Bool
    try
        abs_path = abspath(path)
        hits = scan_hits(abs_path)
        m.path = abs_path
        m.hits = hits
        m.table = _build_table(hits)
        m.current_idx = 0
        m.heatmap = nothing
        m.surf = CairoImageSurface(RGB24[;;])  # invalidate render cache
        if !isempty(hits)
            _load_heatmap!(m)
        else
            m.status_msg = "no hits in $path"
        end
        return true
    catch e
        m.status_msg = "error loading $path: $(typeof(e).__name__) $(e)"
        return false
    end
end

# ── Public entry point ───────────────────────────────────────────────

"""
    run_viewer([path]; theme_name=nothing, gfx=nothing, start_dir=pwd())

Open a Tachikoma TUI showing the hits in `path` (a seticore `.hits`
file). If `path` is omitted, the app starts in browse mode at
`start_dir` (default: the working directory) so the user can navigate
the filesystem and pick a `.hits` file.

The seticore Cap'n Proto schema is embedded in the package as
`SETICORE_SCHEMA_TEXT` and parsed once per session in `__init__` into
the `SETICORE_SCHEMA` Ref; no external schema file is needed.

Pass `theme_name` (e.g. `:NEUROMANCER`) to override the default theme.

The heatmap is rendered via the terminal's native graphics protocol —
Kitty graphics on Kitty/Ghostty, Sixel on WezTerm/iTerm2/foot/mlterm —
falling back to braille sampling on terminals without one. Tachikoma
auto-detects the protocol during startup.

Pass `gfx` to force a specific protocol for this run:
  - `:kitty`  → Kitty graphics protocol
  - `:sixel`  → Sixel
  - `:none`   → braille fallback only
  - `nothing` → auto-detect (default)

`gfx` is implemented by setting the `TACHIKOMA_GFX` environment variable
for the duration of the app, so it takes effect before Tachikoma's
terminal probe runs.

In view mode, press `o` to open the file picker and switch to another
`.hits` file without restarting the app. Press `m` to toggle manual mode,
where the heatmap only loads when you press Enter on a selected hit
(rather than auto-loading as you navigate).
"""
function run_viewer(path::Union{Nothing,AbstractString}=nothing;
                    theme_name=nothing,
                    gfx=nothing,
                    start_dir::AbstractString=pwd())
    theme_name !== nothing && set_theme!(theme_name)

    # Force a graphics protocol for this run by setting the env var that
    # Tachikoma's `enter_tui!` honors before probing the terminal. We save
    # and restore the previous value so callers don't see a leaked env.
    gfx_sym = _normalize_gfx(gfx)
    saved_gfx = get(ENV, "TACHIKOMA_GFX", nothing)
    if gfx_sym !== :auto
        ENV["TACHIKOMA_GFX"] = string(gfx_sym)
    end

    try
        m = HitViewerModel()

        if path !== nothing
            abs_path = abspath(path)
            isfile(abs_path) || error("hits file not found: $abs_path")
            _load_file!(m, abs_path)
        else
            # No path supplied: start in browse mode.
            _open_picker!(m; start_dir=start_dir)
        end

        app(m; fps=30)
    finally
        # Restore the previous TACHIKOMA_GFX value.
        if saved_gfx === nothing
            delete!(ENV, "TACHIKOMA_GFX")
        else
            ENV["TACHIKOMA_GFX"] = saved_gfx
        end
    end
end

"Map a user-supplied gfx spec to one of :auto, :kitty, :sixel, :none."
function _normalize_gfx(gfx)
    gfx === nothing && return :auto
    gfx isa Symbol && return gfx
    gfx isa AbstractString && return Symbol(lowercase(gfx))
    error("gfx must be a Symbol, String, or nothing; got $(typeof(gfx))")
end
