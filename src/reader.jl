# reader.jl ── Cap'n Proto hit reading helpers.
#
# Two passes:
#   1. `scan_hits(path; schema_path=...)` walks every `Hit` message in `path`
#      while skipping the heavy `filterbank.data` field. Returns a vector of
#      `HitMetadata` (small per-hit summaries with the byte offset of each
#      message so the full data can be re-read later).
#   2. `load_hit_data(path, hit::HitMetadata; schema_path=...)` re-reads one
#      message and returns the `filterbank.data` as a `Matrix{Float32}` of
#      size `numChannels × numTimesteps` (column-major: channel is row,
#      timestep is column).
#
# The schema is loaded once and cached per path. Pass `schema_path` to
# override (defaults to a `seticore.capnp` next to the package, or in the
# working directory).

const _DEFAULT_SCHEMA_NAMES = ("seticore.capnp",)

"Look up the seticore schema file: explicit path, then cwd, then package dir."
function _find_schema(schema_path::Union{Nothing,AbstractString}=nothing)
    schema_path !== nothing && return schema_path
    for n in _DEFAULT_SCHEMA_NAMES
        isfile(n) && return n
    end
    pkgdir = joinpath(@__DIR__, "..")
    for n in _DEFAULT_SCHEMA_NAMES
        p = joinpath(pkgdir, n)
        isfile(p) && return p
    end
    error("could not locate seticore.capnp; pass schema_path= explicitly")
end

"Load and parse the schema, with light caching keyed by absolute path."
const _SCHEMA_CACHE = Dict{String,SchemaFile}()
function _load_schema(schema_path::Union{Nothing,AbstractString}=nothing)
    p = abspath(_find_schema(schema_path))
    get!(_SCHEMA_CACHE, p) do
        parse_schema_file(p)
    end
end

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
    scan_hits(path; schema_path=nothing) -> Vector{HitMetadata}

Read every `Hit` message in `path`, skipping the heavy `filterbank.data`
field, and return a vector of lightweight summaries (one per hit) including
each message's byte offset for on-demand re-reading of the data.
"""
function scan_hits(path::AbstractString; schema_path=nothing)
    sf = _load_schema(schema_path)
    meta = HitMetadata[]
    idx = 0
    for (off, hit) in CapnProto.with_offsets(parse_messages(path, sf, "Hit"; skip="filterbank.data"))
        idx += 1
        push!(meta, _to_metadata(idx, off, hit))
    end
    meta
end

"""
    load_hit_data(path, hit::HitMetadata; schema_path=nothing) -> Matrix{Float32}

Re-read the single hit message at the recorded byte offset and return
`filterbank.data` reshaped to `numChannels × numTimesteps` (channel-major
rows, timestep-major columns — `data[c, t]` is channel `c`, timestep `t`).

Per the seticore schema comment, `data` is laid out as
`[t0c0, t0c1, …, t0cN, t1c0, …]` (row-major, timestep-major). Julia arrays
are column-major, so `reshape(raw, numChannels, numTimesteps)` gives a
matrix where element `[c, t]` is channel `c` at timestep `t`.
"""
function load_hit_data(path::AbstractString, hit::HitMetadata; schema_path=nothing)
    sf = _load_schema(schema_path)
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
