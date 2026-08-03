# reader.jl ── Cap'n Proto hit reading helpers.
#
# Two passes:
#   1. `scan_hits(path)` walks every `Hit` message in `path` while skipping
#      the heavy `filterbank.data` field. Returns a vector of `HitMetadata`
#      (small per-hit summaries with the byte offset of each message so
#      the full data can be re-read later).
#   2. `load_hit_data(path, hit)` re-reads one message and returns the
#      `filterbank.data` as a `Matrix{Float32}` of size
#      `numChannels × numTimesteps` (channel-major rows, timestep-major
#      columns).
#
# The schema is the embedded `SETICORE_SCHEMA_TEXT` parsed once in
# `__init__` and stored in `SETICORE_SCHEMA` (a `Ref{SchemaFile}`).

"Construct a HitMetadata from a decoded Hit NamedTuple (no data field)."
function _to_metadata(idx::Int, offset::Int, hit)
    s = hit.signal
    f = hit.filterbank
    HitMetadata(
        idx, offset,
        s.frequency, s.index, s.driftSteps, s.driftRate, s.snr,
        s.coarseChannel, s.beam, s.numTimesteps, s.power, s.incoherentPower,
        f.sourceName, f.fch1, f.foff, f.tstart, f.tsamp, f.ra, f.dec,
        f.telescopeId, f.numTimesteps, f.numChannels,
        f.coarseChannel, f.startChannel, f.beam,
    )
end

"""
    scan_hits(path) -> Vector{HitMetadata}

Read every `Hit` message in `path`, skipping the heavy `filterbank.data`
field, and return a vector of lightweight summaries (one per hit) including
each message's byte offset for on-demand re-reading of the data.
"""
function scan_hits(path::AbstractString)
    sf = SETICORE_SCHEMA[]
    meta = HitMetadata[]
    idx = 0
    for (off, hit) in CapnProto.with_offsets(parse_messages(path, sf, "Hit"; skip="filterbank.data"))
        idx += 1
        push!(meta, _to_metadata(idx, off, hit))
    end
    meta
end

"""
    load_hit_data(path, hit::HitMetadata) -> Matrix{Float32}

Re-read the single hit message at the recorded byte offset and return
`filterbank.data` reshaped to `numChannels × numTimesteps` (channel-major
rows, timestep-major columns — `data[c, t]` is channel `c`, timestep `t`).

Per the seticore schema comment, `data` is laid out as
`[t0c0, t0c1, …, t0cN, t1c0, …]` (row-major, timestep-major). Julia arrays
are column-major, so `reshape(raw, numChannels, numTimesteps)` gives a
matrix where element `[c, t]` is channel `c` at timestep `t`.
"""
function load_hit_data(path::AbstractString, hit::HitMetadata)
    sf = SETICORE_SCHEMA[]
    msg = parse_message(path, sf, "Hit"; pos=hit.offset)
    raw = msg.filterbank.data
    nch = Int(msg.filterbank.numChannels)
    nt  = Int(msg.filterbank.numTimesteps)
    if length(raw) != nch * nt
        error("filterbank.data length ($(length(raw))) != numChannels*numTimesteps ($nch*$nt = $(nch*nt))")
    end
    # raw layout: [t0c0, t0c1, ..., t0cN, t1c0, ...] (row-major, timestep-major)
    # Julia is column-major, so reshape(raw, nch, nt) gives [c, t] indexing.
    return reshape(raw, nch, nt)
end
