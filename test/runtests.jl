# QDOASJulia test suite. Run with:  julia --project -e 'using Pkg; Pkg.test()'
# Copyright (c) 2026 Sunandan Mahant <sunandanmahant@outlook.com>; BSD-3-Clause, see LICENSE.
#
# Uses the synthetic data set of examples/synthetic_data.jl (known true slant columns).
# If the environment variable QDOAS_DOAS_CL points at QDOAS's doas_cl, the port is also
# compared with QDOAS itself on two spectra.

using Test, QDOASJulia, NCDatasets, LinearAlgebra
include(joinpath(@__DIR__, "..", "examples", "synthetic_data.jl"))

const DIR = mktempdir()
const SYN = make_synthetic(DIR; nspec=6)
const P = parse_config(SYN.project)

@testset "QDOASJulia" begin

@testset "version" begin
    toml = read(joinpath(@__DIR__, "..", "Project.toml"), String)
    @test occursin("version = \"$(QDOASJulia.VERSION_STRING)\"", toml)
end

@testset "project file" begin
    @test P.project_name == "Synthetic"
    @test P.swath_name == "QDOAS Results"
    @test [w.name for w in P.windows] == ["SO2", "NO2"]
    @test length(P.spectra) == 6                          # the dark file matches S*? no - and is excluded anyway
    @test all(f -> occursin(r"S\d{7}\.STD$", f), P.spectra)
    @test P.windows[1].poly_order == 3
    @test [c.sym for c in P.windows[1].xs] == ["SO2", "O3", "Ring"]
    @test project_spectra(SYN.project) == P.spectra
end

@testset "recovers the true slant columns" begin
    for (f, t) in zip(SYN.spectra, SYN.truth)
        r = analyze(P; spectrum=f)
        so2, no2 = r.windows
        @test abs(so2.slcol["SO2"] - t.SO2) < 4 * so2.slerr["SO2"]
        @test abs(so2.slcol["O3"] - t.O3) < 4 * so2.slerr["O3"]
        @test abs(no2.slcol["NO2"] - t.NO2) < 4 * no2.slerr["NO2"]
        @test abs(so2.shift["Spectrum"] + t.shift) < 1e-3   # spectrum shifted back by -shift
        @test abs(no2.shift["Ref"] - t.shift) < 1e-3        # reference + cross sections shifted by +shift
        @test so2.rms < 1.5e-3 && no2.rms < 1.5e-3            # photon noise, no systematic misfit
        @test so2.niter >= 1
    end
end

@testset "batch, threads and determinism" begin
    b1 = analyze_spectra(P; threads=false)
    b2 = analyze_spectra(P; threads=true)
    @test all(x -> x.result !== nothing, b1)
    @test [x.file for x in b1] == P.spectra
    for (x, y) in zip(b1, b2), (w1, w2) in zip(x.result.windows, y.result.windows)
        for c in w1.columns
            @test isapprox(w1.slcol[c], w2.slcol[c]; rtol=1e-10, atol=1e-10 * abs(w1.slerr[c]))
        end
    end
    bad = analyze_spectra(P, [P.spectra[1], joinpath(DIR, "missing.STD")])
    @test bad[1].result !== nothing && bad[2].result === nothing && !isempty(bad[2].error)
end

@testset "fit curves" begin
    r = analyze(P; spectrum=P.spectra[3], curves=true)
    cv = r.windows[1].curves
    @test length(cv.lambda) == length(cv.od) == length(cv.model) == length(cv.residual)
    @test cv.od ≈ cv.model .+ cv.residual
    @test sum(c -> c.value, cv.components) ≈ cv.model
    @test all(diff(cv.lambda) .> 0)
    @test r.windows[1].rms ≈ sqrt(sum(abs2, cv.residual) / length(cv.residual)) rtol = 1e-10
end

@testset "outputs" begin
    r = analyze(P; spectrum=P.spectra[2])
    nc = joinpath(DIR, "out.nc")
    write_netcdf(nc, r; config_path=SYN.project)
    NCDataset(nc) do ds
        g = ds.group["QDOAS Results"]
        @test g["Name"][1] == "S0000002"
        @test Int.(g["Date (DD-MM-YYYY)"][:, 1]) == [2026, 9, 29]
        for wr in r.windows
            gw = g.group[wr.name]
            for c in wr.columns
                haskey(gw, "SlCol($c)") && @test gw["SlCol($c)"][1] == wr.slcol[c]
            end
            @test gw["RMS"][1] == wr.rms
            @test Int(gw["iter"][1]) == wr.niter
            @test length(gw["residual_spectrum"][:, 1]) == length(wr.residual)
        end
    end
    csv = write_csv(joinpath(DIR, "out.csv"), analyze_spectra(P))
    lines = readlines(csv)
    @test length(lines) == 1 + length(P.spectra)
    @test occursin("SO2.SlCol(SO2),SO2.SlErr(SO2)", lines[1])
    header, rows = results_table(r)
    @test length(rows) == 1 && rows[1][5] == "ok"
    @test sprint(print_summary, r) |> x -> occursin("SO2", x) && occursin("RMS", x)
end

@testset "command line" begin
    out = joinpath(DIR, "cli")
    @test QDOASJulia.main(["-c", SYN.project, "-o", out, "-q"]) == 0
    @test sort(filter(f -> endswith(f, ".nc"), readdir(out))) == [splitext(basename(f))[1] * ".nc" for f in P.spectra]
    @test isfile(joinpath(out, "results.csv"))
    @test QDOASJulia.main(["-c", SYN.project, "-a", "NotThisProject", "-q"]) == 2
    # a spectrum that cannot be read is reported and makes the exit status 1
    @test QDOASJulia.main(["-c", SYN.project, "-f", joinpath(DIR, "no_such.STD"), "-o", out, "--no-netcdf", "-q"]) == 1
    @test QDOASJulia.main(["-c", SYN.project, "-f", joinpath(dirname(P.spectra[1]), "S00000*.STD"), "-o", joinpath(DIR, "cli2"), "-q"]) == 0
    @test length(readlines(joinpath(DIR, "cli2", "results.csv"))) == 1 + length(P.spectra)
    @test QDOASJulia.main(["--port", "x", "--gui"]) == 2
end

@testset "options that are not implemented are refused" begin
    xml = read(SYN.project, String)
    function refused(from, to)
        f = joinpath(DIR, "variant.xml")
        write(f, replace(xml, from => to; count=1))
        try
            parse_config(f); false
        catch e
            e isa UnsupportedConfig
        end
    end
    @test refused("method=\"ODF\"", "method=\"ML+SVD\"")
    @test refused("kurucz=\"none\"", "kurucz=\"ref\"")
    @test refused("refsel=\"file\"", "refsel=\"auto\"")
    @test refused("cstype=\"interp\"", "cstype=\"convolute\"")
    @test refused("format=\"mfcstd\"", "format=\"ascii\"")
    @test refused("<lowpass_filter selected=\"none\">", "<lowpass_filter selected=\"boxcar\">")
end

@testset "GUI helpers" begin
    e = Dict{String,Any}("SO2" => Dict{String,Any}("exclude" => ["Ring"], "poly_order" => 2, "lmin" => 304.0))
    p2 = QDOASJulia.apply_edits(P, e)
    w = p2.windows[1]
    @test [c.sym for c in w.xs] == ["SO2", "O3"] && w.poly_order == 2 && w.lmin == 304.0
    @test all(g -> !("Ring" in g.symbols), w.shifts)
    @test p2.windows[2] === P.windows[2]
    saved = QDOASJulia.save_edited_project(SYN.project, joinpath(DIR, "edited.xml"), e)
    q = parse_config(saved)
    @test [c.sym for c in q.windows[1].xs] == ["SO2", "O3"] && q.windows[1].poly_order == 2 && q.windows[1].lmin == 304.0
    @test [c.sym for c in q.windows[2].xs] == ["NO2", "O3", "Ring"]
    r1 = analyze(p2; spectrum=P.spectra[1]); r2 = analyze(q; spectrum=P.spectra[1])
    @test r1.windows[1].slcol == r2.windows[1].slcol          # edits in memory == edits saved to file
    @test QDOASJulia.apply_edits(P, Dict("NO2" => Dict("enabled" => false))).windows |> length == 1
end

@testset "spectrum header information" begin
    # MFC STD key = value lines that QDOAS reads; they do not enter the fit
    lines = readlines(P.spectra[1])
    f = joinpath(DIR, "with_angles.STD")
    write(f, join(vcat(lines, ["ElevationAngle = 170", "AzimuthAngle = 20", "Latitude = 40.5"]), "\n") * "\n")
    r = analyze(P; spectrum=f)
    @test r.record.elevation == 10.0 && r.record.azimuth == 200.0     # > 100 degrees looks backwards
    @test r.record.latitude == 40.5 && r.record.longitude == 0.0
    @test r.windows[1].slcol == analyze(P; spectrum=P.spectra[1]).windows[1].slcol
    header, rows = results_table(r)
    @test header[7:9] == ["elevation", "azimuth", "latitude"] && rows[1][7] == 10.0
    @test !("elevation" in results_table(analyze(P; spectrum=P.spectra[2]))[1])
end

@testset "GUI server" begin
    json(resp) = QDOASJulia.JSON3.read(String(resp.body), Dict{String,Any})
    @test QDOASJulia.settings_key(Dict("B" => Dict("x" => 1, "a" => [2, 1]), "A" => Dict())) ==
          QDOASJulia.settings_key(Dict("A" => Dict(), "B" => Dict("a" => [1, 2], "x" => 1.0)))
    @test QDOASJulia.settings_key(nothing) == QDOASJulia.settings_key(Dict()) == "{}"
    @test_throws ArgumentError QDOASJulia.apply_edits(P, Dict("SO2" => Dict("lmin" => 310.0, "lmax" => 310.5)))
    d = json(QDOASJulia.api_project(Dict{String,Any}("path" => SYN.project)))
    @test d["name"] == "Synthetic" && length(d["spectra"]) == 6
    e = Dict{String,Any}("SO2" => Dict{String,Any}("lmin" => 305.0))
    a = json(QDOASJulia.api_analyze(Dict{String,Any}("spectrum" => P.spectra[1], "edits" => e, "baseline" => true)))
    @test [w["name"] for w in a["windows"]] == ["SO2", "NO2"] && haskey(a, "baseline")
    @test a["windows"][1]["curves"]["fit_range"][1] >= 305.0
    @test a["baseline"]["SO2"]["terms"][1]["term"] == "SO2"
    QDOASJulia.api_analyze(Dict{String,Any}("spectrum" => P.spectra[2], "edits" => e))
    t = json(QDOASJulia.api_results(Dict{String,Any}("edits" => e)))
    @test length(t["rows"]) == 2 && t["header"][1] == "file"
    @test isempty(json(QDOASJulia.api_results(Dict{String,Any}("edits" => nothing)))["rows"])
    csv = QDOASJulia.api_results_csv(Dict{String,Any}("edits" => e))
    @test count(==('\n'), String(csv.body)) == 3
    # fit-window map: every cell is the window fitted with that start and end
    QDOASJulia.api_map_start(Dict{String,Any}("spectrum" => P.spectra[3], "window" => "NO2", "edits" => nothing,
        "start_min" => 327.0, "start_max" => 329.0, "end_min" => 343.0, "end_max" => 345.0, "step" => 1.0))
    t0 = time()
    while QDOASJulia.GUI.jobs["map"].running && time() - t0 < 120
        sleep(0.05)
    end
    m = json(QDOASJulia.api_map_status(nothing))["map"]
    @test m["starts"] == [327.0, 328.0, 329.0] && m["ends"] == [343.0, 344.0, 345.0]
    ref = analyze(P; spectrum=P.spectra[3]).windows[2]                 # the project's 328-345 nm
    @test m["cells"][2][3]["scd"]["NO2"] ≈ ref.slcol["NO2"] rtol = 1e-5
    # batch job
    QDOASJulia.api_batch_start(Dict{String,Any}("spectra" => P.spectra, "edits" => nothing))
    t0 = time()
    while QDOASJulia.GUI.jobs["batch"].running && time() - t0 < 120
        sleep(0.05)
    end
    @test length(json(QDOASJulia.api_results(Dict{String,Any}("edits" => nothing)))["rows"]) == 6
    # saving refuses to overwrite the original, and asks before replacing another file
    @test_throws ArgumentError QDOASJulia.api_save(Dict{String,Any}("path" => SYN.project, "edits" => e))
    out = joinpath(DIR, "gui_saved.xml")
    @test json(QDOASJulia.api_save(Dict{String,Any}("path" => out, "edits" => e)))["saved"] == out
    @test haskey(json(QDOASJulia.api_save(Dict{String,Any}("path" => out, "edits" => e))), "exists")
    @test parse_config(out).windows[1].lmin == 305.0
    b = json(QDOASJulia.api_browse(Dict{String,Any}("path" => DIR)))
    @test "spectra" in b["dirs"] && !isempty(b["roots"])
    f = json(QDOASJulia.api_folder(Dict{String,Any}("dir" => DIR, "filter" => "S*.STD", "recursive" => true)))
    @test length(f["spectra"]) == 6
end

# Optional: compare with QDOAS itself (set QDOAS_DOAS_CL=/path/to/doas_cl)
if haskey(ENV, "QDOAS_DOAS_CL") && isfile(ENV["QDOAS_DOAS_CL"])
    @testset "agreement with QDOAS doas_cl" begin
        xml = read(SYN.project, String)
        for f in P.spectra[1:2]
            nc = joinpath(DIR, "q_" * basename(f) * ".nc")
            s = replace(xml, r"<raw_spectra>.*?</raw_spectra>"s => "<raw_spectra><directory name=\"$(dirname(f))\" filters=\"$(basename(f))\" recursive=\"false\" /></raw_spectra>")
            s = replace(s, r"(<output\s+path=\")[^\"]*\"" => SubstitutionString("\\g<1>$nc\""))
            cfg = joinpath(DIR, "q.xml"); write(cfg, s)
            @test success(pipeline(`$(ENV["QDOAS_DOAS_CL"]) -c $cfg -a Synthetic`; stdout=devnull, stderr=devnull))
            r = analyze(P; spectrum=f)
            NCDataset(nc) do ds
                g = ds.group["QDOAS Results"]
                for wr in r.windows, c in wr.columns
                    haskey(g.group[wr.name], "SlCol($c)") || continue
                    q = g.group[wr.name]["SlCol($c)"][1]
                    σ = haskey(g.group[wr.name], "SlErr($c)") ? g.group[wr.name]["SlErr($c)"][1] : abs(q)
                    @test abs(wr.slcol[c] - q) <= 1e-6 * σ
                end
            end
        end
    end
end

end
