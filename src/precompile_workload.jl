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
# the duration of the workload so the reader functions work, then clears
# it so the runtime `__init__` starts from a clean state.

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
            # view mode render — call via Base.invokelatest with model typed
            # as the abstract Model, exactly as Tachikoma's app loop does
            # (app.jl:1178-1185). Direct concrete calls (view(m, f)) don't
            # precompile the specializations reached through the
            # invokelatest + abstract-type barrier; the invokelatest call
            # here ensures view(::HitViewerModel, ::Frame) and every
            # concrete callee it dispatches to (render(::DataTable),
            # render(::PixelImage, ::Rect, ::Frame), render(::StatusBar),
            # _render_view, _render_heatmap, _render_footer, etc.) are
            # compiled with the same dispatch path the runtime uses.
            model::Model = m
            Base.invokelatest(view, model, f)
            # browse mode render (picker path) — also via invokelatest
            _open_picker!(m; start_dir=dirname(tmp_hits))
            Base.invokelatest(view, m, f)

            # ── Sixel/kitty graphics-protocol render paths ───────────
            # The render(::PixelImage, ::Rect, ::Frame) method dispatches
            # on GRAPHICS_PROTOCOL[]: gfx_none → braille fallback (already
            # exercised above), gfx_sixel → encode_sixel + render_graphics!,
            # gfx_kitty → encode_kitty + render_graphics!. The sixel and
            # kitty branches have their own compile costs (~8 ms and ~18 ms
            # for encode_kitty, ~12 ms for render_graphics! with kitty
            # format) that are NOT precompiled by the braille path. Exercise
            # each by temporarily switching the global protocol and
            # re-rendering the heatmap, then restore.
            #
            # Use direct concrete calls here (not invokelatest): the gfx
            # dispatch is on GRAPHICS_PROTOCOL[] (a global Ref), not on
            # the model type, so there's no abstract-type barrier. The
            # concrete render(img, area, f; tick=) call fully specializes
            # the encode_kitty/encode_sixel/render_graphics! kwcalls.
            m.mode = :view
            m.picker = nothing
            saved_gfx = Tachikoma.GRAPHICS_PROTOCOL[]
            # Render the heatmap directly: build a PixelImage, populate it,
            # and call render with each protocol. This bypasses the view
            # dispatch and exercises the exact gfx-branch code paths.
            heat_data = m.heatmap
            if heat_data !== nothing
                heat_pixels = _heatmap_to_pixels(heat_data, m.heatmap_min, m.heatmap_max, 80, 30)
                for gfx in (Tachikoma.gfx_sixel, Tachikoma.gfx_kitty)
                    Tachikoma.GRAPHICS_PROTOCOL[] = gfx
                    img = Tachikoma.PixelImage(60, 30)
                    copyto!(img.pixels, heat_pixels)
                    Tachikoma.render(img, Tachikoma.Rect(1, 1, 60, 30), f; tick=1)
                end
                # Also call the encoders + render_graphics! directly with
                # explicit keywords. The render() call above invokes them
                # via keyword dispatch (Core.kwcall), but @compile_workload
                # may not persist kwcall specializations that are only
                # reached through another function's kwcall. Direct calls
                # here ensure the encoder kwcalls themselves are compiled.
                kdata = Tachikoma.encode_kitty(heat_pixels;
                                               decay=Tachikoma.DecayParams(),
                                               tick=1, cols=60, rows=30)
                sdata = Tachikoma.encode_sixel(heat_pixels;
                                               decay=Tachikoma.DecayParams(),
                                               tick=1)
                Tachikoma.render_graphics!(f, kdata, Tachikoma.Rect(1, 1, 60, 30);
                                           pixels=heat_pixels,
                                           format=Tachikoma.gfx_fmt_kitty)
                Tachikoma.render_graphics!(f, sdata, Tachikoma.Rect(1, 1, 60, 30);
                                           pixels=heat_pixels,
                                           format=Tachikoma.gfx_fmt_sixel)
            end
            Tachikoma.GRAPHICS_PROTOCOL[] = saved_gfx

            # ── Navigation keys via the same invokelatest barrier ─────
            # The app loop dispatches events via
            # `Base.invokelatest(dispatch_event!, ..., model::Model, evt::Event)`
            # (app.jl:1133). Direct concrete update!(m, evt) calls don't
            # precompile the specializations reached through that barrier.
            # Exercise every key symbol our app forwards to the widgets,
            # plus mouse press/scroll, in both modes — all via invokelatest.

            # View mode: DataTable navigation + mouse
            m.mode = :view
            m.picker = nothing
            for k in (:down, :up, :pageup, :pagedown, :home, :end_key,
                      :left, :right)
                Base.invokelatest(update!, model, Tachikoma.KeyEvent(k, Char(0)))
            end
            Base.invokelatest(update!, model, Tachikoma.KeyEvent(:char, 'r'))
            Base.invokelatest(update!, model,
                              Tachikoma.MouseEvent(5, 5, Tachikoma.mouse_left,
                                                   Tachikoma.mouse_press,
                                                   false, false, false))
            Base.invokelatest(update!, model,
                              Tachikoma.MouseEvent(5, 5, Tachikoma.mouse_scroll_down,
                                                   Tachikoma.mouse_press,
                                                   false, false, false))

            # Browse mode: SelectableList navigation + mouse
            _open_picker!(m; start_dir=dirname(tmp_hits))
            for k in (:down, :up, :pageup, :pagedown, :home, :end_key)
                Base.invokelatest(update!, model, Tachikoma.KeyEvent(k, Char(0)))
            end
            Base.invokelatest(update!, model,
                              Tachikoma.MouseEvent(5, 5, Tachikoma.mouse_left,
                                                   Tachikoma.mouse_press,
                                                   false, false, false))
            Base.invokelatest(update!, model,
                              Tachikoma.MouseEvent(5, 5, Tachikoma.mouse_scroll_down,
                                                   Tachikoma.mouse_press,
                                                   false, false, false))
            # Picker-specific keys (return early from _picker_handle_key!,
            # but exercise the dispatch anyway)
            for k in (:enter, :backspace, :escape)
                Base.invokelatest(update!, model, Tachikoma.KeyEvent(k, Char(0)))
            end
            for c in ('h', 'r', 'q')
                Base.invokelatest(update!, model, Tachikoma.KeyEvent(:char, c))
            end
        end

        # ── Explicit precompile() for invokelatest-defeated specializations ──
        # Tachikoma's app loop dispatches events via
        # `Base.invokelatest(dispatch_event!, ..., model::Model, evt::Event)`
        # where `model` is typed as the abstract `Model`. This defeats
        # method specialization across the call boundary, so the
        # concrete specializations `update!(::HitViewerModel, ::KeyEvent)`
        # and `update!(::HitViewerModel, ::MouseEvent)` — and the widget
        # handle_key!/handle_mouse! methods they call — are NOT picked up
        # by `@compile_workload`'s implicit inference. The 10-18 ms cold
        # latency on the first picker :down was exactly this:
        # `handle_key!(::SelectableList, ::KeyEvent)` compiling on first
        # runtime dispatch. Explicit `precompile()` calls force these
        # specializations into the precompile cache.
        precompile(CapnpHitViewer.update!,
                   (HitViewerModel, Tachikoma.KeyEvent))
        precompile(CapnpHitViewer.update!,
                   (HitViewerModel, Tachikoma.MouseEvent))
        precompile(Tachikoma.handle_key!,
                   (Tachikoma.SelectableList, Tachikoma.KeyEvent))
        precompile(Tachikoma.handle_mouse!,
                   (Tachikoma.SelectableList, Tachikoma.MouseEvent))
        precompile(Tachikoma.handle_key!,
                   (Tachikoma.DataTable, Tachikoma.KeyEvent))
        precompile(Tachikoma.handle_mouse!,
                   (Tachikoma.DataTable, Tachikoma.MouseEvent))
        # The picker and view dispatch helpers, also reached via update!
        precompile(CapnpHitViewer._picker_handle_key!,
                   (FilePicker, Tachikoma.KeyEvent))
        precompile(CapnpHitViewer._picker_handle_mouse!,
                   (FilePicker, Tachikoma.MouseEvent))
        precompile(CapnpHitViewer._update_view!,
                   (HitViewerModel, Tachikoma.KeyEvent))

        # ── Render path specializations (same invokelatest barrier) ──
        # Tachikoma's app loop calls `view(model, f)` via
        # `Base.invokelatest() do; view(model, f); end` with
        # `model::Model` (abstract). The concrete specialization
        # `view(::HitViewerModel, ::Frame)` and the widget render methods
        # it calls are NOT picked up by @compile_workload's implicit
        # inference. Measured cold costs:
        #   render(::StatusBar, ::Rect, ::Buffer)  ~100 ms cold
        #   render(::DataTable, ::Rect, ::Buffer)  ~18 ms cold
        #   render(::PixelImage, ::Rect, ::Frame)  ~12 ms cold
        #   view(::HitViewerModel, ::Frame)        ~30 ms cold (sum of above)
        # Force these specializations into the precompile cache.
        precompile(CapnpHitViewer.view, (HitViewerModel, Tachikoma.Frame))
        precompile(CapnpHitViewer._render_view, (HitViewerModel, Tachikoma.Frame))
        precompile(CapnpHitViewer._render_heatmap,
                   (HitViewerModel, Tachikoma.Rect, Tachikoma.Frame))
        precompile(CapnpHitViewer._render_footer,
                   (HitViewerModel, Tachikoma.Rect, Tachikoma.Buffer))
        precompile(CapnpHitViewer._draw_pixel_heatmap,
                   (HitViewerModel, Matrix{Float32}, Tachikoma.Rect, Tachikoma.Frame))
        precompile(CapnpHitViewer._draw_heatmap_info,
                   (HitViewerModel, Matrix{Float32}, Tachikoma.Rect, Tachikoma.Buffer))
        precompile(CapnpHitViewer._render_picker, (FilePicker, Tachikoma.Frame))
        # Tachikoma widget render methods reached through our view path.
        # render(::PixelImage, ::Rect, ::Frame) has a `tick` keyword, so
        # its dispatch goes through Core.kwcall — precompile both forms.
        precompile(Tachikoma.render,
                   (Tachikoma.StatusBar, Tachikoma.Rect, Tachikoma.Buffer))
        precompile(Tachikoma.render,
                   (Tachikoma.DataTable, Tachikoma.Rect, Tachikoma.Buffer))
        precompile(Tachikoma.render,
                   (Tachikoma.PixelImage, Tachikoma.Rect, Tachikoma.Frame))
        precompile(Core.kwcall,
                   (NamedTuple{(:tick,), Tuple{Int}}, typeof(Tachikoma.render),
                    Tachikoma.PixelImage, Tachikoma.Rect, Tachikoma.Frame))
        # Sixel/kitty encoder kwcalls — reached from render(::PixelImage)
        # when GRAPHICS_PROTOCOL[] is gfx_sixel/gfx_kitty. The braille
        # fallback path (gfx_none) doesn't compile these.
        precompile(Core.kwcall,
                   (NamedTuple{(:decay, :tick, :cols, :rows),
                                Tuple{Tachikoma.DecayParams, Int, Int, Int}},
                    typeof(Tachikoma.encode_kitty), Matrix{Tachikoma.ColorRGBA}))
        precompile(Core.kwcall,
                   (NamedTuple{(:decay, :tick),
                                Tuple{Tachikoma.DecayParams, Int}},
                    typeof(Tachikoma.encode_sixel), Matrix{Tachikoma.ColorRGBA}))
        # render_graphics! kwcall (pixels + format keywords) — reached
        # from both sixel and kitty branches.
        precompile(Core.kwcall,
                   (NamedTuple{(:pixels, :format),
                                Tuple{Matrix{Tachikoma.ColorRGBA}, Tachikoma.GraphicsFormat}},
                    typeof(Tachikoma.render_graphics!),
                    Tachikoma.Frame, Vector{UInt8}, Tachikoma.Rect))
        # The app loop's dispatch_event! (also called via invokelatest).
        precompile(Tachikoma.dispatch_event!,
                    (Tachikoma.Terminal, Tachikoma.AppOverlay,
                     HitViewerModel, Tachikoma.KeyEvent, Bool))
        precompile(Tachikoma.dispatch_event!,
                    (Tachikoma.Terminal, Tachikoma.AppOverlay,
                     HitViewerModel, Tachikoma.MouseEvent, Bool))
    finally
        isfile(tmp_hits) && rm(tmp_hits; force=true)
    end
end
