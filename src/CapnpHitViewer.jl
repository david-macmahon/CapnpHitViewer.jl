module CapnpHitViewer

using CapnProto
using Tachikoma
using PrecompileTools: @compile_workload
import Tachikoma: view, update!, should_quit, init!, cleanup!,
                 handle_all_key_actions, copy_rect, task_queue,
                 recording_enabled, has_pending_output, set_wake!

export run_viewer, HitMetadata, SETICORE_SCHEMA, SETICORE_SCHEMA_TEXT

# ── Embedded seticore schema ──────────────────────────────────────────
#
# The schema text is embedded as a string constant so the package is
# self-contained (no external file lookup at runtime). It is parsed in
# `__init__` into the `SETICORE_SCHEMA` Ref, which the rest of the
# package reads via `SETICORE_SCHEMA[]`.

const SETICORE_SCHEMA_TEXT = raw"""@0xb811e7262df2bb01;

struct Signal {
  frequency @0 :Float64;
  index @1 :Int32;
  driftSteps @2 :Int32;
  driftRate @3 :Float64;
  snr @4 :Float32;
  coarseChannel @5 :Int32;
  beam @6 :Int32;
  numTimesteps @7 :Int32;
  power @8 :Float32;
  incoherentPower @9 :Float32;
}

struct Filterbank {
  sourceName @0 :Text;
  fch1 @1 :Float64;
  foff @2 :Float64;
  tstart @3 :Float64;
  tsamp @4 :Float64;
  ra @5 :Float64;
  dec @6 :Float64;
  telescopeId @7 :Int32;
  numTimesteps @8 :Int32;
  numChannels @9 :Int32;
  data @10 :List(Float32);
  coarseChannel @11 :Int32;
  startChannel @12 :Int32;
  beam @13 :Int32;
}

struct Hit {
  signal @0 :Signal;
  filterbank @1 :Filterbank;
}

struct Event {
  hits @0 :List(Hit);
}

struct Stamp {
  seticoreVersion @13 :Text;
  sourceName @0 :Text;
  ra @1 :Float64;
  dec @2 :Float64;
  fch1 @3 :Float64;
  foff @4 :Float64;
  tstart @5 :Float64;
  tsamp @6 :Float64;
  telescopeId @7 :Int32;
  numTimesteps @8 :Int32;
  numChannels @9 :Int32;
  numPolarizations @10 :Int32;
  numAntennas @11 :Int32;
  data @12 :List(Float32);
  coarseChannel @14 :Int32;
  fftSize @15 :Int32;
  startChannel @16 :Int32;
  signal @17 :Signal;
  schan @18 :Int32;
  obsid @19 :Text;
}
"""

"Parsed seticore schema, filled by `__init__`. Read via `SETICORE_SCHEMA[]`."
const SETICORE_SCHEMA = Ref{SchemaFile}()

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

end # module
