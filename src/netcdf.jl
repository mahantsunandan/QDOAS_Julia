# This file is part of QDOASJulia, a Julia port of the QDOAS DOAS analysis core.
# Copyright (c) 2026 Sunandan Mahant <sunandanmahant@outlook.com>
# Derived from QDOAS, Copyright (C) 1994-2025 BIRA-IASB and S[&]T (BSD-3-Clause).
# See LICENSE and NOTICE.md.

# =============================================================================
# NetCDF output in QDOAS's layout (output_netcdf.cpp), so that everything reading
# qdoas_results.nc works unchanged.
# =============================================================================

const QDOAS_FILL_INT = Int32(-2147483647)

# NCDatasets takes one global lock around every netCDF call. Several analyses writing
# at once then hand that lock back and forth hundreds of times per file, and a 40 ms
# write took 600 ms with six in flight. netCDF runs one call at a time regardless, so
# write whole files one at a time instead.
const NC_WRITE_LOCK = ReentrantLock()

"""
    write_netcdf(path, result; config_path="")

Writes `result` (from analyze_config) to `path` exactly as doas_cl lays out its
NetCDF: a group named after the project's swathName (usually "QDOAS Results") with
the record fields, then one group per window
holding its variables in QDOAS's order.
"""
function write_netcdf(path::AbstractString, res; config_path::AbstractString="")
    lock(NC_WRITE_LOCK) do
        p = res.spec
        rec = res.record
        isfile(path) && rm(path)
        NCDataset(path, "c") do ds
            g = defGroup(ds, p.swath_name)
            g.attrib["CreationTime"] = Libc.strftime("%a %b %e %H:%M:%S %Y\n", time())
            g.attrib["Qdoas"] = "Results obtained using QDOASJulia $(VERSION_STRING), a Julia port of " *
                                "the Qdoas analysis (BIRA-IASB and S[&]T); not produced by Qdoas itself"
            g.attrib["InputFile"] = p.spectrum
            g.attrib["QDOASConfigProject"] = p.project_name
            g.attrib["QDOASConfig"] = String(config_path)

            defDim(g, "n_alongtrack", 1)
            "date" in p.fields && defDim(g, "date", 3)
            "time" in p.fields && defDim(g, "time", 3)
            if any(wr -> any(kv -> startswith(first(kv), "Stretch(") || startswith(first(kv), "Err Stretch("), wr.nc_vars), res.windows)
                defDim(g, "2", 2)
            end
            for wr in res.windows
                for (k, v) in wr.nc_vars
                    k == "residual_spectrum" && defDim(g, "$(wr.name).n_datapoint", length(v))
                end
            end

            for f in p.fields
                if f == "name"
                    v = defVar(g, "Name", String, ("n_alongtrack",))
                    v[1] = rec.name
                elseif f == "date"
                    v = defVar(g, "Date (DD-MM-YYYY)", Int32, ("date", "n_alongtrack"); fillvalue=QDOAS_FILL_INT)
                    v[:, 1] = Int32.(collect(rec.date))
                elseif f == "time"
                    v = defVar(g, "Time (hh:mm:ss)", Int32, ("time", "n_alongtrack"); fillvalue=QDOAS_FILL_INT)
                    v[:, 1] = Int32.(collect(rec.time))
                end
            end

            for wr in res.windows
                gw = defGroup(g, wr.name)
                for (k, v) in wr.nc_attribs
                    gw.attrib[k] = v
                end
                for (k, v) in wr.nc_vars
                    if v isa Int32
                        x = defVar(gw, k, Int32, ("n_alongtrack",); fillvalue=QDOAS_FILL_INT)
                        x[1] = v
                    elseif k == "residual_spectrum"
                        x = defVar(gw, k, Float64, ("$(wr.name).n_datapoint", "n_alongtrack"); fillvalue=QDOAS_FILL_DOUBLE)
                        x[:, 1] = v
                    elseif v isa AbstractVector
                        x = defVar(gw, k, Float64, ("2", "n_alongtrack"); fillvalue=QDOAS_FILL_DOUBLE)
                        x[:, 1] = v
                    else
                        x = defVar(gw, k, Float64, ("n_alongtrack",); fillvalue=QDOAS_FILL_DOUBLE)
                        x[1] = Float64(v)
                    end
                end
            end
        end
        path
    end
end

"""
    run_config(xml_path, nc_path) -> result

Like `doas_cl -c xml_path -a <project>` for one spectrum: analyses the project's
spectrum and writes the NetCDF to `nc_path`. Throws `UnsupportedConfig` for options
this port does not implement (use QDOAS for those) and `EngineError` where QDOAS
itself would fail.
"""
function run_config(xml_path::AbstractString, nc_path::AbstractString)
    res = analyze_config(xml_path)
    write_netcdf(nc_path, res; config_path=xml_path)
    res
end
