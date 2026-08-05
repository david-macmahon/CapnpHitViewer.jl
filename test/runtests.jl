using Test
using CapnProto
using CapnpHitViewer
using CapnpHitViewer: scan_hits, load_hit_data, HitMetadata

const SAMPLE = joinpath(@__DIR__, "sample.hits")

@testset "CapnpHitViewer" begin
    @testset "schema parsed" begin
        @test SETICORE_SCHEMA[] isa CapnProto.SchemaFile
    end

    @testset "scan_hits" begin
        hits = scan_hits(SAMPLE)
        @test length(hits) == 3
        @test all(h isa HitMetadata for h in hits)
        # 1-based indices, contiguous
        @test [h.index for h in hits] == [1, 2, 3]
        # offsets are non-negative and strictly increasing
        offs = [h.offset for h in hits]
        @test all(>=(0), offs)
        @test issorted(offs)
    end

    @testset "source names" begin
        hits = scan_hits(SAMPLE)
        @test [h.sourceName for h in hits] == ["CYGNUS-X1", "VEGA", "TAU_CETI"]
    end

    @testset "channel counts (69, 66, 62)" begin
        hits = scan_hits(SAMPLE)
        @test [h.numChannels for h in hits] == [69, 66, 62]
    end

    @testset "all hits share numTimesteps and tstart" begin
        hits = scan_hits(SAMPLE)
        @test all(h.fbNumTimesteps == hits[1].fbNumTimesteps for h in hits)
        @test all(h.tstart == hits[1].tstart for h in hits)
    end

    @testset "beam numbers 0, 1, 2" begin
        hits = scan_hits(SAMPLE)
        @test [Int(h.beam) for h in hits] == [0, 1, 2]
    end

    @testset "VEGA (alien head) metadata" begin
        hits = scan_hits(SAMPLE)
        vega = hits[2]
        @test vega.frequency ≈ 1420.405752
        @test vega.driftRate ≈ 3.1415926
        @test Float64(vega.snr) ≈ 10 * exp(1) rtol=1e-5
    end

    @testset "fch1 centers band on frequency" begin
        hits = scan_hits(SAMPLE)
        for h in hits
            center = h.fch1 + h.foff * h.numChannels / 2
            @test center ≈ h.frequency
        end
    end

    @testset "load_hit_data" begin
        hits = scan_hits(SAMPLE)
        for (i, h) in enumerate(hits)
            data = load_hit_data(SAMPLE, h)
            @test size(data) == (h.numChannels, h.fbNumTimesteps)
            @test eltype(data) == Float32
        end
    end

    @testset "VEGA data is non-trivial" begin
        hits = scan_hits(SAMPLE)
        vega = hits[2]
        data = load_hit_data(SAMPLE, vega)
        # The alien head has lit (high-value) and dark (low-value) regions.
        @test maximum(data) > 0
        @test minimum(data) >= 0
        # Not all the same value (it has structure + noise).
        @test length(unique(data)) > 100
    end

    @testset "random hits are random" begin
        hits = scan_hits(SAMPLE)
        for i in (1, 3)
            data = load_hit_data(SAMPLE, hits[i])
            # Fully random data: no two identical rows.
            rows = [data[:, t] for t in 1:size(data, 2)]
            @test !all(rows[1] .== rows[2])
        end
    end
end
