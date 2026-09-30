# Compare QDOASJulia with QDOAS (doas_cl) on the same project and spectra.
# Copyright (c) 2026 Sunandan Mahant <sunandanmahant@outlook.com>; BSD-3-Clause, see LICENSE.
#
# Usage:
#   julia --project=/path/to/QDOAS_Julia validation/compare_with_qdoas.jl \
#         --doas-cl /path/to/doas_cl -c project.xml [-f spectrum ...] [--keep DIR]
#
# For each spectrum it writes a copy of the project that points at just that spectrum,
# runs `doas_cl` on it, analyses the same spectrum with QDOASJulia, and compares every
# slant column QDOAS wrote, in units of QDOAS's own error (Δ/σ), plus RMS and the
# iteration count. doas_cl needs ~2 GB of memory per run; spectra run one at a time.

using QDOASJulia, NCDatasets, Printf, Statistics

function parse_args(args)
    o = Dict{String,Any}("files" => String[], "keep" => "")
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--doas-cl"; o["doas_cl"] = args[i+1]; i += 2
        elseif a in ("-c", "--config"); o["config"] = args[i+1]; i += 2
        elseif a in ("-f", "--file"); push!(o["files"], args[i+1]); i += 2
        elseif a == "--keep"; o["keep"] = args[i+1]; i += 2
        else error("unknown argument $a")
        end
    end
    haskey(o, "doas_cl") && haskey(o, "config") || error("usage: --doas-cl PATH -c PROJECT.xml [-f SPECTRUM ...]")
    o
end

"The project, pointed at one spectrum and a given NetCDF output, asking for RMS/chi/iterations."
function single_spectrum_project(xml::String, spectrum::String, nc::String)
    s = replace(xml, r"<raw_spectra>.*?</raw_spectra>"s =>
        "<raw_spectra>\n      <directory name=\"$(dirname(abspath(spectrum)))\" filters=\"$(basename(spectrum))\" recursive=\"false\" />\n    </raw_spectra>")
    s = replace(s, r"(<output\s+path=\")[^\"]*\"" => SubstitutionString("\\g<1>$nc\""))
    for f in ("rms", "chi", "iter_number")
        occursin("<field name=\"$f\"", s) && continue
        s = replace(s, r"(<output\s+path=[^>]*>)" => SubstitutionString("\\g<1>\n      <field name=\"$f\" />"); count=1)
    end
    s
end

function main(args)
    o = parse_args(args)
    xml = read(o["config"], String)
    p = parse_config(o["config"])
    files = isempty(o["files"]) ? p.spectra : o["files"]
    work = isempty(o["keep"]) ? mktempdir() : mkpath(o["keep"])
    dsig = Float64[]; rmsrel = Float64[]; itmis = 0; nwin = 0; failed = 0
    @printf("%d spectra, doas_cl = %s\n", length(files), o["doas_cl"])
    for f in files
        tag = splitext(basename(f))[1]
        nc = joinpath(work, tag * ".nc"); rm(nc; force=true)
        cfg = joinpath(work, tag * ".xml")
        write(cfg, single_spectrum_project(xml, f, nc))
        t = @elapsed ok = success(pipeline(`$(o["doas_cl"]) -c $cfg -a $(p.project_name)`,
                                           stdout=joinpath(work, tag * ".log"), stderr=joinpath(work, tag * ".log")))
        if !ok || !isfile(nc)
            println("  $tag: doas_cl failed (see $(joinpath(work, tag * ".log")))"); failed += 1; continue
        end
        tj = @elapsed res = analyze(p; spectrum=f)
        line = @sprintf("  %-14s doas_cl %5.2f s, QDOASJulia %6.1f ms |", tag, t, 1000tj)
        NCDataset(nc) do ds
            g = ds.group[p.swath_name]
            for wr in res.windows
                gw = g.group[wr.name]; nwin += 1
                worst = 0.0
                for (k, v) in gw
                    m = match(r"^SlCol\((.*)\)$", k)
                    (m === nothing || !haskey(gw, "SlErr($(m[1]))") || !haskey(wr.slcol, m[1])) && continue
                    d = abs(wr.slcol[m[1]] - v[1]) / gw["SlErr($(m[1]))"][1]
                    push!(dsig, d); worst = max(worst, d)
                end
                haskey(gw, "RMS") && push!(rmsrel, abs(wr.rms - gw["RMS"][1]) / gw["RMS"][1])
                haskey(gw, "iter") && Int(gw["iter"][1]) != wr.niter && (itmis += 1)
                line *= @sprintf(" %s max %.1e σ", wr.name, worst)
            end
        end
        println(line)
    end
    println()
    @printf("windows compared: %d, doas_cl failures: %d, iteration-count differences: %d\n", nwin, failed, itmis)
    isempty(dsig) || @printf("slant columns: %d, |Δ|/σ median %.1e, max %.1e\n", length(dsig), median(dsig), maximum(dsig))
    isempty(rmsrel) || @printf("RMS relative difference: max %.1e\n", maximum(rmsrel))
    isempty(o["keep"]) && rm(work; recursive=true, force=true)
end

main(ARGS)
