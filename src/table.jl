# This file is part of QDOASJulia, a Julia port of the QDOAS DOAS analysis core.
# Copyright (c) 2026 Sunandan Mahant <sunandanmahant@outlook.com>
# Derived from QDOAS, Copyright (C) 1994-2025 BIRA-IASB and S[&]T (BSD-3-Clause).
# See LICENSE and NOTICE.md.

# =============================================================================
# Tables and summaries
# =============================================================================

"The quantities of one window result as (column name => value) pairs, in a fixed order."
function window_quantities(wr::WindowResult)
    q = Pair{String,Float64}[]
    push!(q, "RMS" => wr.rms, "Chi2" => wr.chisqr, "iterations" => wr.niter)
    for c in wr.columns
        push!(q, "SlCol($c)" => wr.slcol[c], "SlErr($c)" => wr.slerr[c])
    end
    for s in sort(collect(keys(wr.shift)))
        push!(q, "Shift($s)" => wr.shift[s], "Err Shift($s)" => wr.shift_err[s])
    end
    for s in sort(collect(keys(wr.stretch)))
        push!(q, "Stretch($s)" => wr.stretch[s], "Err Stretch($s)" => wr.stretch_err[s])
    end
    for k in sort(collect(keys(wr.params)))
        push!(q, k => wr.params[k], "Err $k" => wr.param_err[k])
    end
    q
end

fmt_date(d) = @sprintf("%04d-%02d-%02d", d...)
fmt_time(t) = @sprintf("%02d:%02d:%02d", t...)

"""
    results_table(batch) -> (header, rows)

One row per spectrum of an `analyze_spectra` batch (or a single `analyze` result):
file, record name, date, mid-exposure time (UTC as in the file), status, error, the
viewing `elevation` and `azimuth` angles and the `latitude` and `longitude` when any
spectrum's header gives them, then for every window `Window.RMS`, `Window.Chi2`, `Window.iterations`, `Window.SlCol(X)`,
`Window.SlErr(X)` for each fitted term (cross sections, then polynomial `x0..`),
shifts, stretches and non-linear offsets with their errors. SCDs are in the units of
the cross sections (molecules/cm² for cross sections in cm²/molecule); shifts in nm.
"""
function results_table(batch::AbstractVector)
    cols = String[]; seen = Set{String}()
    for b in batch
        b.result === nothing && continue
        for wr in b.result.windows, (k, _) in window_quantities(wr)
            name = "$(wr.name).$k"
            name in seen || (push!(cols, name); push!(seen, name))
        end
    end
    meta = [f for f in (:elevation, :azimuth, :latitude, :longitude)
            if any(b -> b.result !== nothing && !isnan(getfield(b.result.record, f)), batch)]
    header = vcat(["file", "name", "date", "time", "status", "error"], String.(meta), cols)
    rows = Vector{Vector{Any}}()
    for b in batch
        r = b.result
        row = Any[b.file, "", "", "", r === nothing ? "failed" : "ok", b.error]
        vals = Dict{String,Float64}()
        if r !== nothing
            row[2] = r.record.name
            row[3] = fmt_date(r.record.date)
            row[4] = fmt_time(r.record.time)
            for wr in r.windows, (k, v) in window_quantities(wr)
                vals["$(wr.name).$k"] = v
            end
        end
        append!(row, [r === nothing || isnan(getfield(r.record, f)) ? missing : getfield(r.record, f) for f in meta])
        append!(row, [get(vals, c, missing) for c in cols])
        push!(rows, row)
    end
    header, rows
end

results_table(result::NamedTuple) = haskey(result, :windows) ?
    results_table([(file=result.spectrum, result=result, error="", seconds=0.0)]) : results_table([result])

csv_cell(x::AbstractFloat) = isfinite(x) ? @sprintf("%.10g", x) : ""
csv_cell(::Missing) = ""
csv_cell(x) = (s = string(x); occursin(r"[,\"\n]", s) ? "\"" * replace(s, "\"" => "\"\"") * "\"" : s)

"""
    write_csv(path, batch_or_result) -> path

Writes `results_table` as comma-separated values.
"""
function write_csv(path::AbstractString, batch)
    header, rows = results_table(batch)
    open(path, "w") do io
        println(io, join(csv_cell.(header), ','))
        for r in rows
            println(io, join(csv_cell.(r), ','))
        end
    end
    path
end

"""
    print_summary([io,] result)

Human-readable summary of an `analyze` result: per window the RMS, χ², iterations,
every slant column with its error, and the shifts and stretches.
"""
function print_summary(io::IO, res)
    r = res.record
    @printf(io, "%s  %s %s UTC  (%s)\n", r.name, fmt_date(r.date), fmt_time(r.time), basename(res.spectrum))
    for wr in res.windows
        show(io, MIME("text/plain"), wr)
        println(io)
    end
end
print_summary(res) = print_summary(stdout, res)

function Base.show(io::IO, ::MIME"text/plain", wr::WindowResult)
    @printf(io, "  %s: RMS %.3e, chi2 %.3e, %d iterations\n", wr.name, wr.rms, wr.chisqr, wr.niter)
    for c in wr.columns
        @printf(io, "    %-22s % .4e ± %.2e\n", c, wr.slcol[c], wr.slerr[c])
    end
    # QDOAS gives a parameter that is not fitted an error of exactly 1
    for s in sort(collect(keys(wr.shift)))
        if wr.shift_err[s] == 1.0
            @printf(io, "    shift(%s) % .5f nm (fixed)", s, wr.shift[s])
        else
            @printf(io, "    shift(%s) % .5f ± %.5f nm", s, wr.shift[s], wr.shift_err[s])
        end
        get(wr.stretch_err, s, 1.0) != 1.0 && @printf(io, ", stretch % .3e ± %.1e", wr.stretch[s], wr.stretch_err[s])
        println(io)
    end
end
Base.show(io::IO, wr::WindowResult) = print(io, "WindowResult(", wr.name, ", RMS=", round(wr.rms; sigdigits=4), ")")
