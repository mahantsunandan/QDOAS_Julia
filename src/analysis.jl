# This file is part of QDOASJulia, a Julia port of the QDOAS DOAS analysis core.
# Copyright (c) 2026 Sunandan Mahant <sunandanmahant@outlook.com>
# Derived from QDOAS, Copyright (C) 1994-2025 BIRA-IASB and S[&]T (BSD-3-Clause).
# See LICENSE and NOTICE.md.

# =============================================================================
# Analysing spectra: one (ANALYSE_Spectrum over all windows), or many in parallel
# =============================================================================

"""
    analyze(p::ProjectSpec; spectrum=p.spectrum, curves=false) -> result
    analyze(xml_path; spectrum=..., curves=false)

Runs every enabled analysis window of the project on one spectrum (an MFC STD file)
and returns a named tuple:

  * `spec`      the `ProjectSpec` used (with `spec.spectrum` set to the spectrum)
  * `spectrum`  path of the analysed spectrum
  * `lambda`    wavelength calibration of the reference, nm
  * `windows`   one `WindowResult` per analysis window (SCDs, errors, shifts, ...)
  * `record`    spectrum metadata: name, date, mid-exposure time, scans, exposure
  * `raw`       the spectrum after offset/dark correction, before normalisation

With `curves=true` each `WindowResult` also carries the fitted curves (`.curves`) for
plotting. Throws `UnsupportedConfig` or `EngineError` (see their docstrings).
"""
function analyze(p::ProjectSpec; spectrum::AbstractString=p.spectrum, curves::Bool=false)
    isempty(spectrum) && throw(ArgumentError("no spectrum: the project lists none, pass spectrum=\"...\""))
    p = spectrum == p.spectrum ? p : respec(p; spectrum=String(spectrum))
    n = p.n_det
    spec, record = load_spectrum(p)
    raw = copy(spec)
    spe_norm = normalize!(spec)

    results = WindowResult[]
    xs_cache = Dict()
    lam_ref = Dict{String,Tuple{Vector{Float64},Vector{Float64},Float64}}()
    lam = Float64[]
    for ws in p.windows
        lr, ref, ref_norm = get!(lam_ref, ws.refone) do
            cached((ws.refone, :reference, n)) do
                l, v = load_two_columns(ws.refone, n)
                v2 = copy(v)
                nrm = normalize!(v2)
                (l, v2, nrm)
            end
        end
        lam = lr
        # ANALYSE_Spectrum skips a window whose spectrum equals its reference
        if all(i -> (ref[i] == 0 ? spec[i] == ref[i] : abs(spec[i] - ref[i]) / abs(ref[i]) <= 1e-7), 1:n)
            throw(EngineError("spectrum identical to reference in $(ws.name)"))
        end
        w = build_window(ws, p, lr, xs_cache)
        push!(results, window_result(w, p, spec, ref; spe_norm=spe_norm, ref_norm=ref_norm, curves=curves))
    end
    (spec=p, spectrum=p.spectrum, lambda=lam, windows=results, record=record, raw=raw)
end

analyze(xml_path::AbstractString; kw...) = analyze(parse_config(xml_path); kw...)

"""
    analyze_config(xml_path; spectrum=nothing, curves=false)

Parses a QDOAS project and analyses one spectrum: the given one, or the project's
first. Same result as `analyze`.
"""
function analyze_config(xml_path::AbstractString; spectrum=nothing, curves::Bool=false)
    p = parse_config(xml_path)
    analyze(p; spectrum=something(spectrum, p.spectrum), curves=curves)
end

"""
    analyze_spectra(p, files=project_spectra(p); threads=true, curves=false, on_progress=nothing)
        -> Vector of (file, result, error, seconds)

Analyses many spectra with one project. A spectrum that cannot be analysed gets
`result = nothing` and its error message; the others are unaffected. Results come
back in the order of `files`.

When Julia runs with several threads (`julia -t auto`) and `threads=true`, spectra are
fitted in parallel; OpenBLAS is set to one thread meanwhile, since many small fits
at once are faster that way (results are unchanged to ~1e-16). `on_progress(done,
total, file)` is called after each spectrum, one call at a time.
"""
function analyze_spectra(p::ProjectSpec, files::AbstractVector{<:AbstractString}=p.spectra;
                         threads::Bool=true, curves::Bool=false, on_progress=nothing)
    out = Vector{Any}(undef, length(files))
    done = Threads.Atomic{Int}(0)
    lk = ReentrantLock()
    function work(i)
        f = String(files[i])
        t0 = time()
        out[i] = try
            (file=f, result=analyze(p; spectrum=f, curves=curves), error="", seconds=time() - t0)
        catch e
            e isa InterruptException && rethrow()
            (file=f, result=nothing, error=sprint(showerror, e), seconds=time() - t0)
        end
        k = Threads.atomic_add!(done, 1) + 1
        on_progress === nothing || lock(() -> on_progress(k, length(files), f), lk)
        nothing
    end
    parallel = threads && Threads.nthreads() > 1 && length(files) > 1
    nblas = BLAS.get_num_threads()
    parallel && BLAS.set_num_threads(1)
    try
        if parallel
            Threads.@threads :dynamic for i in eachindex(files)
                work(i)
            end
        else
            foreach(work, eachindex(files))
        end
    finally
        parallel && BLAS.set_num_threads(nblas)
    end
    [x for x in out]
end

analyze_spectra(xml_path::AbstractString, args...; kw...) = analyze_spectra(parse_config(xml_path), args...; kw...)
