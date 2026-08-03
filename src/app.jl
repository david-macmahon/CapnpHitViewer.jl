# app.jl ── Tachikoma TUI for browsing seticore .hits files.
#
# Layout:
#   ┌───────────────────────────────────────────────────────────┐
#   │ title bar                                                  │
#   ├──────────────────────┬────────────────────────────────────┤
#   │ hit table            │ heatmap (PixelImage)               │
#   │ (DataTable)          │ filterbank.data reshaped to        │
#   │                      │ numChannels × numTimesteps         │
#   │                      │                                    │
#   ├──────────────────────┴────────────────────────────────────┤
#   │ status bar / keybindings                                   │
#   └───────────────────────────────────────────────────────────┘
#
# Keys:
#   ↑/↓/PgUp/PgDn/Home/End  navigate hits (heatmap auto-reloads)
#   r     reload data for current hit (re-reads the capnp message)
#   q/Esc quit

@kwdef mutable struct HitViewerModel <: Model
    quit::Bool = false
    tick::Int = 0
    path::String = ""                  # hits file path
    schema_path::String = ""           # schema file path (empty = auto)
    hits::Vector{HitMetadata} = HitMetadata[]
    # DataTable over `hits`
    table::DataTable = DataTable(String[], Any[])
    # Cached heatmap data for the currently selected hit
    current_idx::Int = 0               # 1-based index into hits; 0 = none
    heatmap::Union{Nothing,Matrix{Float32}} = nothing
    heatmap_min::Float32 = 0.0f0
    heatmap_max::Float32 = 1.0f0
    status_msg::String = ""
end

should_quit(m::HitViewerModel) = m.quit

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
        DataColumn("Frequency", freq;    align=col_right,
                   format=v -> string(v, " Hz")),
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

# ── Heatmap colour mapping ───────────────────────────────────────────
#
# A simple viridis-like ramp: dark blue → cyan → green → yellow → red,
# mapping normalized value [0,1] to an RGB triple. Implementation is
# piecewise linear interpolation between five anchor colours.

const _HEATMAP_STOPS = (
    (0.00, (0x00, 0x00, 0x00)),  # black
    (0.25, (0x1f, 0x0c, 0x48)),  # deep purple
    (0.50, (0x6a, 0x1b, 0x9a)),  # magenta
    (0.75, (0xff, 0x6b, 0x1a)),  # orange
    (1.00, (0xff, 0xff, 0x66)),  # pale yellow
)

function _heatmap_color(v::Real)::ColorRGBA
    vf = clamp(Float64(v), 0.0, 1.0)
    @inbounds for i in 1:(length(_HEATMAP_STOPS) - 1)
        a = _HEATMAP_STOPS[i]
        b = _HEATMAP_STOPS[i+1]
        if vf ≤ b[1]
            t = (vf - a[1]) / (b[1] - a[1])
            ar, ag, ab = a[2]
            br, bg, bb = b[2]
            r = clamp(round(Int, ar + t * (br - ar)), 0, 255)
            g = clamp(round(Int, ag + t * (bg - ag)), 0, 255)
            bl = clamp(round(Int, ab + t * (bb - ab)), 0, 255)
            return ColorRGBA(UInt8(r), UInt8(g), UInt8(bl))
        end
    end
    ColorRGBA(_HEATMAP_STOPS[end][2]...)
end

"Build a ColorRGBA matrix (pixel_h × pixel_w) from the heatmap data by
nearest-neighbour sampling, with one pixel per data cell when the canvas
is small, and 1:1 mapping when large. Orientation: channels (rows of the
data matrix) run along the heatmap's vertical axis, timesteps along the
horizontal axis."
function _heatmap_to_pixels(data::Matrix{Float32}, vmin::Float32, vmax::Float32,
                            pw::Int, ph::Int)::Matrix{ColorRGBA}
    nch, nt = size(data)
    out = fill(canvas_bg(), ph, pw)
    span = vmax > vmin ? Float64(vmax - vmin) : 1.0
    @inbounds for py in 1:ph
        sy = clamp(ceil(Int, (py - 0.5) / ph * nch + 0.5), 1, nch)
        for px in 1:pw
            sx = clamp(ceil(Int, (px - 0.5) / pw * nt + 0.5), 1, nt)
            v = (data[sy, sx] - vmin) / span
            out[py, px] = _heatmap_color(v)
        end
    end
    out
end

# ── Heatmap loading / caching ────────────────────────────────────────

function _load_heatmap!(m::HitViewerModel)
    idx = m.table.selected
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
        data = load_hit_data(m.path, hit; schema_path=isempty(m.schema_path) ? nothing : m.schema_path)
        m.heatmap = data
        m.heatmap_min = isempty(data) ? 0.0f0 : Float32(minimum(data))
        m.heatmap_max = isempty(data) ? 1.0f0 : Float32(maximum(data))
        m.current_idx = idx
        m.status_msg = "loaded hit $idx: $(size(data,1)) channels × $(size(data,2)) timesteps"
    catch e
        m.heatmap = nothing
        m.current_idx = 0
        m.status_msg = "error loading hit $idx: $(typeof(e).__name__) $(e)"
    end
end

# ── Event handling ───────────────────────────────────────────────────

function update!(m::HitViewerModel, evt::KeyEvent)
    # Delegate to the table for navigation/sort/etc.
    if m.table.show_detail
        handle_key!(m.table, evt)
        return
    end

    if evt.key == :char
        evt.char == 'q' && (m.quit = true; return)
        evt.char == 'r' && begin
            # Force reload
            m.current_idx = 0
            _load_heatmap!(m)
            return
        end
    end
    evt.key == :escape && (m.quit = true; return)

    # Let the table handle navigation; reload heatmap if selection changed.
    prev = m.table.selected
    handled = handle_key!(m.table, evt)
    if handled && m.table.selected != prev
        _load_heatmap!(m)
    end
end

function update!(m::HitViewerModel, evt::MouseEvent)
    # Forward to the table for click-to-select / scroll
    prev = m.table.selected
    handle_mouse!(m.table, evt)
    if m.table.selected != prev
        _load_heatmap!(m)
    end
end

# ── View ─────────────────────────────────────────────────────────────

function view(m::HitViewerModel, f::Frame)
    m.tick += 1
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

    # ── Body: left = table, right = heatmap ──
    # Vertical separator column eats 1 char.  Table gets 60%, heatmap fill.
    body_cols = split_layout(Layout(Horizontal, [Percent(60), Fixed(1), Fill()]), body_area)
    length(body_cols) < 3 && return
    table_area = body_cols[1]
    sep_area   = body_cols[2]
    heat_area  = body_cols[3]

    # Render the table
    m.table.block = Block(title="Signals",
                          border_style=tstyle(:border),
                          title_style=tstyle(:title))
    m.table.tick = m.tick
    render(m.table, table_area, buf)

    # Render the separator
    for ry in sep_area.y:bottom(sep_area)
        set_char!(buf, sep_area.x, ry, BOX_PLAIN.v, tstyle(:border, dim=true))
    end

    # Render the heatmap
    _render_heatmap(m, heat_area, f)

    # ── Footer ──
    _render_footer(m, footer_area, buf)
end

function _render_heatmap(m::HitViewerModel, area::Rect, f::Frame)
    buf = f.buffer

    # Block + title
    block = Block(title="Heatmap (channels ↑, timesteps →)",
                  border_style=tstyle(:border),
                  title_style=tstyle(:title))
    inner = render(block, area, buf)

    # If no hit is selected, just clear interior with a hint
    if m.heatmap === nothing
        msg = m.current_idx == 0 && m.table.selected == 0 ?
              "no hit selected" :
              "select a hit to load its filterbank.data"
        mx = inner.x + max(0, (inner.width - length(msg)) ÷ 2)
        my = inner.y + max(0, inner.height ÷ 2)
        set_string!(buf, mx, my, msg, tstyle(:text_dim, dim=true))
        return
    end

    data = m.heatmap
    nch, nt = size(data)

    # Split inner into the pixel canvas area + a small info strip below.
    info_h = 3
    if inner.height <= info_h + 1
        # Too short for an info strip — use the whole inner area
        _draw_pixel_heatmap(m, data, inner, f)
        return
    end
    rows = split_layout(Layout(Vertical, [Fill(), Fixed(info_h)]), inner)
    _draw_pixel_heatmap(m, data, rows[1], f)
    _draw_heatmap_info(m, data, rows[2], buf)
end

function _draw_pixel_heatmap(m::HitViewerModel, data::Matrix{Float32}, area::Rect, f::Frame)
    if area.width < 2 || area.height < 2
        return
    end
    img = PixelImage(area.width, area.height)
    pixels = _heatmap_to_pixels(data, m.heatmap_min, m.heatmap_max,
                                img.pixel_w, img.pixel_h)
    # Push the pixels into the image buffer directly.
    copyto!(img.pixels, pixels)
    render(img, area, f; tick=m.tick)
end

function _draw_heatmap_info(m::HitViewerModel, data::Matrix{Float32}, area::Rect, buf::Buffer)
    nch, nt = size(data)
    hit = m.table.selected > 0 && m.table.selected ≤ length(m.hits) ? m.hits[m.table.selected] : nothing

    line1 = if hit !== nothing
        "fch1=$(round(hit.fch1; digits=4))  foff=$(round(hit.foff; digits=8))  tsamp=$(round(hit.tsamp; digits=6))"
    else
        ""
    end
    line2 = "min=$(round(Float64(m.heatmap_min); digits=4))  max=$(round(Float64(m.heatmap_max); digits=4))  " *
            "channels=$nch  timesteps=$nt"
    line3 = "range: $(m.heatmap_min) → $(m.heatmap_max)"

    set_string!(buf, area.x, area.y, line1, tstyle(:text_dim); max_x=right(area))
    set_string!(buf, area.x, area.y + 1, line2, tstyle(:text); max_x=right(area))
    set_string!(buf, area.x, area.y + 2, line3, tstyle(:text_dim); max_x=right(area))
end

# ── Status bar ───────────────────────────────────────────────────────

function _render_footer(m::HitViewerModel, area::Rect, buf::Buffer)
    status = m.status_msg
    if isempty(status)
        status = isempty(m.hits) ? "no hits loaded" : "ready"
    end
    render(StatusBar(
        left=[Span("  [↑↓]navigate [r]reload [q/Esc]quit ",
                    tstyle(:text_dim))],
        right=[Span(status, tstyle(:accent, bold=true))],
    ), area, buf)
end

# ── Public entry point ───────────────────────────────────────────────

"""
    run_viewer(path; schema_path=nothing, theme_name=nothing)

Open a Tachikoma TUI showing the hits in `path` (a seticore `.hits`
file). `schema_path` defaults to `seticore.capnp` in the cwd or next
to the package. Pass `theme_name` (e.g. `:NEUROMANCER`) to override the
default theme.
"""
function run_viewer(path::AbstractString; schema_path=nothing, theme_name=nothing)
    theme_name !== nothing && set_theme!(theme_name)

    abs_path = abspath(path)
    isfile(abs_path) || error("hits file not found: $abs_path")

    # First pass: scan all hit metadata (skipping the heavy data field).
    hits = scan_hits(abs_path; schema_path=schema_path)
    table = _build_table(hits)

    m = HitViewerModel(path=abs_path,
                       schema_path=schema_path === nothing ? "" : abspath(schema_path),
                       hits=hits,
                       table=table)

    # Load the heatmap for the initially selected hit.
    if !isempty(hits)
        _load_heatmap!(m)
    end

    app(m; fps=30)
end
