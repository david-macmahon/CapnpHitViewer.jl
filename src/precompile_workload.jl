# precompile_workload.jl ── install-time precompilation of hot paths.
#
# The single biggest user-facing latency is Julia compiling methods on
# the first call.  Measured cold costs (precompile cache cleared):
#
#   parse_schema                ~1300 ms   (schema parser)
#   first iterate(MessageIterator) ~2000 ms   (parse_messages + read_struct)
#   load_hit_data / parse_message   ~730 ms
#   _build_table (DataTable ctor)   ~550 ms
#   _heatmap_to_pixels              ~190 ms
#   _draw_pixel_heatmap (PixelImage + render) ~2300 ms
#   FilePicker ctor                 ~720 ms
#   view (full view-mode render)   ~3240 ms
#   update! (handle_key! DataTable) ~140 ms
#
# All of these depend only on types, not runtime values, so a single
# exercised call per method signature moves the compile cost into
# `Pkg.precompile`/install time.  The workload below builds a tiny
# synthetic `.hits` file in a temp directory using CapnProto.build_message
# so it works on any machine without external sample data.
#
# Note: `__init__` does NOT run during precompilation, so `SETICORE_SCHEMA[]`
# is empty here.  The workload parses `SETICORE_SCHEMA_TEXT` directly (which
# is exactly what `__init__` will do at runtime) and populates the Ref for
# the duration of the workload so the reader functions work.

"Build a single minimal Hit message as a packed Cap'n Proto byte vector."
function _make_synthetic_hit(sf::SchemaFile, frequency::Float64)::Vector{UInt8}
    hit = (
        signal = (
            frequency = frequency,
            index = Int32(0),
            driftSteps = Int32(1),
            driftRate = 0.1,
            snr = Float32(10.0),
            coarseChannel = Int32(0),
            beam = Int32(0),
            numTimesteps = Int32(2),
            power = Float32(1.0),
            incoherentPower = Float32(1.0),
        ),
        filterbank = (
            sourceName = "synthetic",
            fch1 = 1000.0,
            foff = 1.0,
            tstart = 0.0,
            tsamp = 1.0,
            ra = 0.0,
            dec = 0.0,
            telescopeId = Int32(0),
            numTimesteps = Int32(2),
            numChannels = Int32(3),
            # data layout: [t0c0, t0c1, t0c2, t1c0, t1c1, t1c2] (2 timesteps × 3 channels)
            data = Float32[1.0f0, 2.0f0, 3.0f0, 4.0f0, 5.0f0, 6.0f0],
            coarseChannel = Int32(0),
            startChannel = Int32(0),
            beam = Int32(0),
        ),
    )
    build_message(hit, sf, "Hit"; packed=true)
end

"Write `n` synthetic hits concatenated into a temp `.hits` file and return its path."
function _write_synthetic_hits(sf::SchemaFile, n::Int=3)::String
    path = mktemp()[1] * ".hits"
    open(path, "w") do io
        for i in 1:n
            write(io, _make_synthetic_hit(sf, Float64(i)))
        end
    end
    path
end

@compile_workload begin
    # parse_schema on the embedded text — same call __init__ will make at
    # runtime (~1300 ms cold). This compiles parse_schema and the lexer/
    # parser internals.
    sf = parse_schema(SETICORE_SCHEMA_TEXT)

    # Populate the Ref so scan_hits / load_hit_data (which read
    # SETICORE_SCHEMA[]) work during the workload. __init__ will
    # unconditionally overwrite this at runtime, so no cleanup needed.
    SETICORE_SCHEMA[] = sf

    # Write a tiny synthetic .hits file and scan it.
    # parse_messages + first iterate (~2000 ms cold) + _to_metadata
    tmp_hits = _write_synthetic_hits(sf, 3)
    try
        hits = scan_hits(tmp_hits)
        if !isempty(hits)
            # load_hit_data / parse_message + reshape (~730 ms cold)
            data = load_hit_data(tmp_hits, hits[1])

            # ── Table / heatmap path ────────────────────────────────
            # _build_table / DataTable ctor (~550 ms cold)
            table = _build_table(hits)

            # _heatmap_to_pixels inner loop + _heatmap_color (~190 ms cold)
            vmin = Float32(minimum(data))
            vmax = Float32(maximum(data))
            _heatmap_to_pixels(data, vmin, vmax, 80, 30)

            # ── FilePicker ctor (~720 ms cold) ──────────────────────
            # Use dirname(tmp_hits) so the picker sees a real directory.
            FilePicker(start_dir=dirname(tmp_hits))

            # ── Full view + update path through TestBackend ─────────
            # Pulls in render(::DataTable), render(::PixelImage, ::Rect, ::Frame)
            # (the braille fallback, ~2300 ms cold), render(::StatusBar),
            # render(::Block), set_string!, handle_key!(::DataTable),
            # and update! (~140 ms cold).
            tb = Tachikoma.TestBackend(120, 40)
            f = Tachikoma.Frame(tb.buf,
                                Tachikoma.Rect(1, 1, 120, 40),
                                Tachikoma.GraphicsRegion[],
                                Tachikoma.PixelSnapshot[])
            m = HitViewerModel(path=tmp_hits, hits=hits, table=table)
            _load_heatmap!(m)
            # view mode render
            view(m, f)
            # browse mode render (picker path)
            _open_picker!(m; start_dir=dirname(tmp_hits))
            view(m, f)
            # update! paths: navigate in view mode
            m.mode = :view
            m.picker = nothing
            update!(m, Tachikoma.KeyEvent(:down, Char(0)))
            update!(m, Tachikoma.KeyEvent(:char, 'r'))
            # update! path: picker key handling
            _open_picker!(m; start_dir=dirname(tmp_hits))
            update!(m, Tachikoma.KeyEvent(:enter, Char(0)))
            update!(m, Tachikoma.KeyEvent(:backspace, Char(0)))
            update!(m, Tachikoma.KeyEvent(:char, 'h'))
            update!(m, Tachikoma.KeyEvent(:escape, Char(0)))
        end
    finally
        isfile(tmp_hits) && rm(tmp_hits; force=true)
    end
end
