module CapnpHitViewer

using CapnProto
using Tachikoma
import Tachikoma: view, update!, should_quit, init!, cleanup!,
                 handle_all_key_actions, copy_rect, task_queue,
                 recording_enabled, has_pending_output, set_wake!

export run_viewer, HitMetadata
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

end # module
