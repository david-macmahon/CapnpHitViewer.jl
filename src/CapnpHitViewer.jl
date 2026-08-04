module CapnpHitViewer

using CapnProto
using Tachikoma
using CairoMakie
using CairoMakie.Cairo: CairoImageSurface, CairoSurfaceImage
using CairoMakie.Colors: RGB24
using PrecompileTools: @compile_workload
using Printf: @sprintf
# Tachikoma and Makie both export MouseEvent (and possibly other names).
# Explicitly import the Tachikoma bindings we use unqualified so the
# `using Tachikoma` above doesn't create ambiguities now that Makie is
# also loaded.
import Tachikoma: MouseEvent, KeyEvent
import Tachikoma: Fixed, Rect, bottom, right, set_theme!
import Tachikoma: view, update!, should_quit, init!, cleanup!,
                 handle_all_key_actions, copy_rect, task_queue,
                 recording_enabled, has_pending_output, set_wake!

export run_viewer, HitMetadata, SETICORE_SCHEMA, SETICORE_SCHEMA_TEXT

include("schema.jl")

function __init__()
    SETICORE_SCHEMA[] = parse_schema(SETICORE_SCHEMA_TEXT)
end

"""
    HitMetadata

Lightweight per-hit summary: the signal fields plus enough filterbank
metadata to build the table. The heavy `filterbank.data` field is read
on demand when a hit is selected for the heatmap view.
"""
struct HitMetadata
    index::Int                # 1-based position in the file
    offset::Int               # 0-based byte offset of the message in the file (for re-reading)
    # Signal fields
    frequency::Float64
    signalIndex::Int32
    driftSteps::Int32
    driftRate::Float64
    snr::Float32
    coarseChannel::Int32
    beam::Int32
    numTimesteps::Int32
    power::Float32
    incoherentPower::Float32
    # Filterbank metadata
    sourceName::String
    fch1::Float64
    foff::Float64
    tstart::Float64
    tsamp::Float64
    ra::Float64
    dec::Float64
    telescopeId::Int32
    fbNumTimesteps::Int32
    numChannels::Int32
    fbCoarseChannel::Int32
    startChannel::Int32
    fbBeam::Int32
end

include("reader.jl")
include("filepicker.jl")
include("app.jl")
include("precompile_workload.jl")

# Entry point for the `hitsviewer` Pkg.App (see [apps] in Project.toml).
# Runs run_viewer with the first positional arg as the hits file path,
# or with no path (browse mode) when no args are given.
function (@main)(ARGS=[])
    path = isempty(ARGS) ? nothing : ARGS[1]
    run_viewer(path)
end

end # module
