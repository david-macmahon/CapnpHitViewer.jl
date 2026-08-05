# Generates test/sample.hits with a few hits, one of which has
# filterbank data shaped like the alien head emoji (👽) when plotted
# as a heatmap (channels on x-axis, timesteps on y-axis, yreversed).
using CapnProto
using CapnpHitViewer: SETICORE_SCHEMA_TEXT
using Random

# ── Alien head pattern ────────────────────────────────────────────────
# Grid is nch (width) × nt (height). Data layout per seticore schema is
# [t0c0, t0c1, ..., t0cN, t1c0, ...] (timestep-major, row-major). Julia
# reshape(raw, nch, nt) gives data[c, t] indexing.
#
# The heatmap renders channels on x and timesteps on y with yreversed,
# so t=1 is at the TOP. We design the pattern in (x=channel, y=timestep)
# with y growing downward in the design grid, then it displays right-side-up.

function alien_head_pattern(nch::Int, nt::Int;
                            border::Int=2,
                            noise_std::Float64=0.08,
                            head_value::Float32=0.18f0)::Matrix{Float32}
    # Normalized coordinates: x, y in [-1, 1], origin at center.
    # y grows downward in design space (matches timestep index growing down).
    pat = zeros(Float32, nch, nt)
    for c in 1:nch, t in 1:nt
        x = (c - 0.5) / nch * 2 - 1      # [-1, 1]
        y = (t - 0.5) / nt * 2 - 1       # [-1, 1], +1 = bottom row
        # _alien_value returns 1.0 for head interior, 0.0 for eyes/background.
        pat[c, t] = _alien_value(x, y) * head_value
    end
    # Add a few-pixel border ring around the whole grid (dim but visible,
    # close to the noise floor so it doesn't dominate).
    _add_border!(pat, border, head_value * 0.7f0)
    # Sprinkle background noise so the heatmap isn't perfectly clean.
    pat .+= Float32.(noise_std .* randn(size(pat)))
    # Clamp: head/interior stays within range, background noise bounded.
    clamp!(pat, 0.0f0, head_value + 3 * noise_std)
    pat
end

# Shape function: returns 0.0 (background) or 1.0 (head/eyes).
function _alien_value(x::Float64, y::Float64)::Float32
    # Head outline: an egg/oval, taller than wide. WIDE at top
    # (negative y) and NARROW at the bottom (positive y) — inverted egg
    # with a strongly tapered chin. Shrunk (ry < 1) so the whole head
    # sits inside the border ring with margin on all sides.
    ry = 0.82        # vertical extent: head spans y ∈ [-0.82, 0.82]
    rx = 0.70        # horizontal extent: leaves side margin inside border
    # Outside the head bounds entirely.
    abs(y) > ry && return 0.0f0

    # Half-width from the ellipse, then taper the chin (lower half) extra
    # so it narrows to a point well before the bottom of the grid.
    ellipse_hw = rx * sqrt(max(0.0, 1.0 - (y / ry)^2))
    # Quadratic chin taper: gentle near the middle, moderate toward the
    # bottom, narrowing to ~0.25 of the ellipse width at y = ry (a soft
    # point rather than a sharp one).
    chin = y > 0 ? 1.0 - 0.60 * (y / ry)^2 : 1.0
    head_hw = ellipse_hw * chin

    # Inside head?
    if abs(x) <= head_hw
        # Eyes: two almond shapes, slanted, in upper half (y < 0).
        ex = 0.32   # horizontal center of each eye
        ey = -0.22  # vertical center (upper half — the WIDE part)
        eye_w = 0.26
        eye_h = 0.14
        slant = 0.22

        for sx in (-1, 1)
            cx = sx * ex
            dy = y - ey
            shift = slant * (-dy) * sx
            lx = (x - (cx + shift)) / eye_w
            ly = dy / eye_h
            r2 = lx^2 + ly^2
            if r2 <= 1.0
                return 0.0f0  # eyes are dark (carved out)
            end
        end

        # Smile: a thin arc (carved out) in the lower half, centered
        # horizontally. Modeled as a thin annular strip: points close to
        # a circle of radius `sr` (within `thickness`) and below the
        # smile's center `sy` (lower half of the arc only, giving a
        # ∩-shape that opens downward = an upright smile).
        sy = 0.12     # vertical center of the smile arc
        sr = 0.22     # radius of the arc (width of the smile)
        thickness = 0.055
        dx = x
        dy = y - sy
        r = sqrt(dx^2 + dy^2)
        if abs(r - sr) <= thickness && dy >= 0 && abs(x) <= sr
            return 0.0f0  # mouth is dark (carved out)
        end

        return 1.0f0
    end

    0.0f0
end

"Draw a dim border ring `b` pixels thick around the edge of `pat`."
function _add_border!(pat::Matrix{Float32}, b::Int, v::Float32)
    b < 1 && return
    nch, nt = size(pat)
    for c in 1:nch, t in 1:nt
        if c <= b || c > nch - b || t <= b || t > nt - b
            pat[c, t] = max(pat[c, t], v)
        end
    end
end

# ── Build a hit with given data matrix ────────────────────────────────
function make_hit(sf::SchemaFile, frequency::Float64, data::Matrix{Float32};
                  sourceName="synthetic",
                  driftRate=0.1,
                  snr=Float32(10.0),
                  tstart=0.0,
                  ra=0.0,
                  dec=0.0,
                  beam::Int=0)::Vector{UInt8}
    nch, nt = size(data)
    # Flatten timestep-major: data[c, t] -> [t0c0, t0c1, ..., t0cN, t1c0, ...]
    flat = reshape(permutedims(data, (2, 1)), :)
    hit = (
        signal = (
            frequency = frequency,
            index = Int32(0),
            driftSteps = Int32(1),
            driftRate = driftRate,
            snr = snr,
            coarseChannel = Int32(0),
            beam = Int32(beam),
            numTimesteps = Int32(nt),
            power = Float32(1.0),
            incoherentPower = Float32(1.0),
        ),
        filterbank = (
            sourceName = sourceName,
            fch1 = frequency - 1e-6 * nch / 2,  # center the band on frequency
            foff = 1e-6,                        # 1 Hz in MHz
            tstart = tstart,
            tsamp = 1.0,
            ra = ra,
            dec = dec,
            telescopeId = Int32(0),
            numTimesteps = Int32(nt),
            numChannels = Int32(nch),
            data = flat,
            coarseChannel = Int32(0),
            startChannel = Int32(0),
            beam = Int32(beam),
        ),
    )
    build_message(hit, sf, "Hit"; packed=true)
end

# ── Write the hits file ───────────────────────────────────────────────
sf = parse_schema(SETICORE_SCHEMA_TEXT)
mkpath("test")
path = joinpath("test", "sample.hits")

const ALIEN_FREQ = 1420.405752  # MHz (HI line)
const ALIEN_NT = 66             # timesteps (doubled from 33)
const ALIEN_TSTART = 0.0
rng = MersenneTwister(20260804)

# Hit 1: fully random data, same ntimesteps + tstart as the alien head.
# 3 more channels than the alien head (66 + 3 = 69).
small = rand(rng, Float32, ALIEN_NT + 3, ALIEN_NT)
# Hit 2: the alien head (HI frequency, pi drift, e-based SNR).
# Doubled resolution (66×66), inverted egg (wide top/narrow bottom),
# transposed so it displays upright in the heatmap.
alien = Matrix(transpose(alien_head_pattern(ALIEN_NT, ALIEN_NT;
                                              border=2,
                                              noise_std=0.03,
                                              head_value=0.12f0)))
# Hit 3: fully random data.
# 4 fewer channels than the alien head (66 - 4 = 62).
small2 = rand(rng, Float32, ALIEN_NT - 4, ALIEN_NT)

# Random frequencies within ±10 MHz of the alien head, but keep the alien
# itself on the HI line.
freq1 = ALIEN_FREQ + (rand(rng) - 0.5) * 20.0
freq3 = ALIEN_FREQ + (rand(rng) - 0.5) * 20.0

open(path, "w") do io
    write(io, make_hit(sf, freq1, small;
                      sourceName="CYGNUS-X1",
                      ra=19.972687705555554, dec=35.201606805555556,
                      beam=0,
                      tstart=ALIEN_TSTART))
    write(io, make_hit(sf, ALIEN_FREQ, alien;
                      sourceName="VEGA",
                      ra=18.61564898611111, dec=38.78368894444444,
                      driftRate=3.1415926,
                      snr=Float32(10 * exp(1)),
                      beam=1,
                      tstart=ALIEN_TSTART))
    write(io, make_hit(sf, freq3, small2;
                      sourceName="TAU_CETI",
                      ra=1.7344675, dec=-15.937480555555556,
                      beam=2,
                      tstart=ALIEN_TSTART))
end

println("wrote $path")
println("alien head: $(size(alien)) channels × timesteps, ",
        "$(count(>(0.5f0), alien)) lit cells of $(length(alien))")
println("freq1 = $freq1 MHz")
println("freq3 = $freq3 MHz")
