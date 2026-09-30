# This file is part of QDOASJulia, a Julia port of the QDOAS DOAS analysis core.
# Copyright (c) 2026 Sunandan Mahant <sunandanmahant@outlook.com>
# Derived from QDOAS, Copyright (C) 1994-2025 BIRA-IASB and S[&]T (BSD-3-Clause).
# See LICENSE and NOTICE.md.

# =============================================================================
# Minimal XML attribute access. QDOAS project files are machine-written by the
# QDOAS GUI; only element attributes and simple nesting are ever needed.
# =============================================================================

attrs(tag::AbstractString) = Dict{String,String}(String(m[1]) => String(m[2])
                                                  for m in eachmatch(r"([\w:]+)\s*=\s*\"([^\"]*)\"", tag))

strip_comments(s) = replace(s, r"<!--.*?-->"s => "")

"First opening tag `<name ...>` in `s` (attributes only)."
function first_tag(s::AbstractString, name::AbstractString)
    m = match(Regex("<" * name * raw"\b([^>]*)>"), s)
    m === nothing ? nothing : attrs(m[1])
end

"All `<name ...>...</name>` blocks (or self-closing tags) in `s`."
function blocks(s::AbstractString, name::AbstractString)
    out = String[]
    for m in eachmatch(Regex("<" * name * raw"\b[^>]*?(?:/>|>.*?</" * name * ">)", "s"), s)
        push!(out, m.match)
    end
    out
end

getf(d, k, default=0.0) = (v = get(d, k, ""); isempty(v) ? default : parse(Float64, v))
getb(d, k) = lowercase(get(d, k, "false")) == "true"

# =============================================================================
# Configuration model
# =============================================================================

struct ShiftGroup
    symbols::Vector{String}
    sh_fit::Bool
    st_type::Int          # 0 none, 1 first order, 2 second order
    sh_init::Float64
    st_init::Float64
    st_init2::Float64
    sh_delta::Float64
    st_delta::Float64
    st_delta2::Float64
    sh_min::Float64
    sh_max::Float64
    sh_store::Bool
    st_store::Bool
    err_store::Bool
end

struct CrossSpec
    sym::String
    file::String
    action::Symbol        # :none (use as is) or :interp
end

struct WindowSpec
    name::String
    lmin::Float64
    lmax::Float64
    lambda0::Float64
    refone::String
    xs::Vector{CrossSpec}
    poly_order::Int       # -1 = no polynomial
    offl_order::Int       # linear offset order, -1 = none
    offl_ref::Bool        # linear offset normalised by the reference (else by the radiance)
    # non-linear offset: (fit, init, delta) for orders 0,1,2
    off::NTuple{3,Tuple{Bool,Float64,Float64}}
    shifts::Vector{ShiftGroup}
    gaps::Vector{Tuple{Float64,Float64}}
    outputs::Dict{String,Tuple{Bool,Bool,Float64}}  # sym => (store SlCol, store SlErr, sfact)
    poly_store::Tuple{Bool,Bool}                # xfit, xerr
    offl_store::Tuple{Bool,Bool}                # offfit, offerr
    off_store::NTuple{3,Tuple{Bool,Bool}}       # o?fstr, o?estr
    save_residuals::Bool
end

struct ProjectSpec
    interpolation::Symbol     # :spline or :linear
    security_gap::Int
    convergence::Float64
    max_iterations::Int
    spike_tolerance::Float64
    n_det::Int
    revert::Bool
    calib::String
    dark::String
    offset::String
    spectrum::String                            # the spectrum `analyze` uses by default
    spectra::Vector{String}                     # every spectrum the project lists
    windows::Vector{WindowSpec}
    fields::Vector{String}                      # project <output> fields, in order
    date_format::String                         # mfcstd date layout
    project_name::String
    swath_name::String                          # NetCDF results group (output swathName)
end

function poly_order_of(v::AbstractString)
    # mapToPolyType: "0".."8" -> ANLYS_POLY_TYPE_0.., anything else NONE (0);
    # mediate then uses polyOrder = type - 1, so "4" -> order 4 (x0..x4).
    v = strip(v)
    return (v in string.(0:8)) ? parse(Int, v) : -1
end

"""
    parse_config(xml_path) -> ProjectSpec

Reads a QDOAS project file (`.xml`, as saved by the QDOAS GUI) and rejects, with
`UnsupportedConfig`, anything this port does not reproduce exactly. The project's
first spectrum becomes `spectrum`; `project_spectra` lists all of them.
"""
function parse_config(xml_path::AbstractString)
    s = strip_comments(read(xml_path, String))

    a = something(first_tag(s, "analysis"), Dict{String,String}())
    get(a, "method", "ODF") == "ODF" || unsupported("analysis method $(get(a, "method", ""))")
    get(a, "fit", "none") == "none" || unsupported("fit weighting $(get(a, "fit", ""))")
    get(a, "unit", "nm") == "nm" || unsupported("unit $(get(a, "unit", ""))")
    interp = get(a, "interpolation", "spline")
    interp in ("spline", "linear") || unsupported("interpolation $interp")

    for f in ("lowpass_filter", "highpass_filter")
        t = first_tag(s, f)
        t !== nothing && get(t, "selected", "none") != "none" && unsupported("$f $(t["selected"])")
    end

    inst = first_tag(s, "instrumental")
    (inst !== nothing && get(inst, "format", "") == "mfcstd") || unsupported("instrument format")
    m = first_tag(s, "mfcstd")
    getb(m, "straylight") && unsupported("straylight correction")

    # the dark, offset and calibration files often sit in the spectra folder and match
    # its filter; they are inputs, not measurements
    aux = Set(abspath(get(m, k, "")) for k in ("dark", "offset", "calib") if !isempty(get(m, k, "")))
    spectra = filter(f -> !(abspath(f) in aux), expand_raw_spectra(s))
    spectrum = isempty(spectra) ? "" : first(spectra)

    windows = WindowSpec[]
    for blk in blocks(s, "analysis_window")
        wa = attrs(match(r"<analysis_window\b([^>]*)>", blk)[1])
        getb(wa, "disable") && continue
        get(wa, "kurucz", "none") == "none" || unsupported("kurucz $(wa["kurucz"]) in $(wa["name"])")
        get(wa, "refsel", "file") == "file" || unsupported("automatic reference in $(wa["name"])")

        files = something(first_tag(blk, "files"), Dict{String,String}())
        isempty(strip(get(files, "reftwo", ""))) || unsupported("second reference in $(wa["name"])")
        refone = strip(get(files, "refone", ""))
        isempty(refone) && unsupported("no reference file in $(wa["name"])")

        xs = CrossSpec[]
        for ct in eachmatch(r"<cross_section\b([^>]*)>", blk)
            c = attrs(ct[1])
            t = get(c, "cstype", "none")
            action = t == "none" ? :none : t == "interp" ? :interp : unsupported("cstype $t ($(c["sym"]))")
            get(c, "ortho", "None") in ("None", "none", "") || unsupported("orthogonalisation ($(c["sym"]))")
            get(c, "amftype", "none") == "none" || unsupported("AMF ($(c["sym"]))")
            getb(c, "cstrncc") && unsupported("constrained concentration ($(c["sym"]))")
            getb(c, "ccfit") || unsupported("fixed concentration ($(c["sym"]))")
            getf(c, "icc") == 0 || unsupported("initial concentration ($(c["sym"]))")
            haskey(c, "subtract") && !isempty(c["subtract"]) && lowercase(c["subtract"]) != "none" &&
                unsupported("subtraction ($(c["sym"]))")
            haskey(c, "correction") && !(lowercase(c["correction"]) in ("none", "")) &&
                unsupported("correction $(c["correction"]) ($(c["sym"]))")
            push!(xs, CrossSpec(c["sym"], c["csfile"], action))
        end

        lin = something(first_tag(blk, "linear"), Dict{String,String}())
        oorder = poly_order_of(get(lin, "offpoly", "none"))
        porder = poly_order_of(get(lin, "xpoly", "none"))
        poly_order_of(get(lin, "xbase", "none")) >= 0 && unsupported("orthogonal base in $(wa["name"])")

        nl = something(first_tag(blk, "nonlinear"), Dict{String,String}())
        for p in ("sol", "com", "u1", "u2", "ram", "resol")
            (getb(nl, p * "fit") || getf(nl, p * "init") != 0) &&
                !(p == "sol" && !getb(nl, "solfit") && getf(nl, "solinit") in (0.0, 1.0)) &&
                unsupported("non-linear '$p' in $(wa["name"])")
        end
        delt(k) = (d = getf(nl, k); abs(d) < EPSILON ? 1.0e-3 : d)
        off = ((getb(nl, "o0fit"), getf(nl, "o0init"), delt("o0delt")),
               (getb(nl, "o1fit"), getf(nl, "o1init"), delt("o1delt")),
               (getb(nl, "o2fit"), getf(nl, "o2init"), delt("o2delt")))

        shifts = ShiftGroup[]
        for sb in blocks(blk, "shift_stretch")
            sa = attrs(match(r"<shift_stretch\b([^>]*)>", sb)[1])
            syms = [String(x[1]) for x in eachmatch(r"<symbol\s+name=\"([^\"]*)\"", sb)]
            sh = get(sa, "shfit", "none")
            st = get(sa, "stfit", "none")
            sdelt(k) = (d = getf(sa, k); abs(d) < EPSILON ? 1.0e-3 : d)
            push!(shifts, ShiftGroup(syms, sh in ("true", "nonlinear"),
                                     st == "1st" ? 1 : st == "2nd" ? 2 : 0,
                                     getf(sa, "shini"), getf(sa, "stini"), getf(sa, "stini2"),
                                     sdelt("shdel"), sdelt("stdel"), sdelt("stdel2"),
                                     getf(sa, "shmin"), getf(sa, "shmax"),
                                     getb(sa, "shstr"), getb(sa, "ststr"), getb(sa, "errstr")))
        end

        gaps = Tuple{Float64,Float64}[]
        for g in eachmatch(r"<gap\b([^>]*)>", blk)
            ga = attrs(g[1])
            push!(gaps, (getf(ga, "min"), getf(ga, "max")))
        end

        outputs = Dict{String,Tuple{Bool,Bool,Float64}}()
        for ot in eachmatch(r"<output\s+sym=([^>]*)>", blk)
            oa = attrs("sym=" * ot[1])
            (getb(oa, "amf") || getb(oa, "vcol") || getb(oa, "verr")) && unsupported("vertical columns in $(wa["name"])")
            outputs[oa["sym"]] = (getb(oa, "scol"), getb(oa, "serr"), getf(oa, "sfact", 1.0))
        end
        off_store = ((getb(nl, "o0fstr"), getb(nl, "o0estr")),
                     (getb(nl, "o1fstr"), getb(nl, "o1estr")),
                     (getb(nl, "o2fstr"), getb(nl, "o2estr")))

        lmin, lmax = getf(wa, "min"), getf(wa, "max")
        l0 = haskey(wa, "lambda0") ? getf(wa, "lambda0") : 0.5 * (lmin + lmax)
        abs(l0) < EPSILON && (l0 = 0.5 * (lmin + lmax))
        # ANALYSE_LoadNonLinear: a fitted non-linear offset alongside a linear one is
        # rejected by QDOAS ("Offset (linear <-> non linear fit)")
        oorder >= 0 && any(k -> off[k][1] || abs(off[k][2]) > 1e-6, 1:3) &&
            throw(EngineError("linear and non-linear offset both set in $(wa["name"])"))
        push!(windows, WindowSpec(wa["name"], lmin, lmax, l0, refone, xs, porder, oorder, getb(lin, "offizero"),
                                  off, shifts, gaps,
                                  outputs, (getb(lin, "xfit"), getb(lin, "xerr")),
                                  (getb(lin, "offfit"), getb(lin, "offerr")), off_store,
                                  getb(files, "saveresiduals")))
    end
    isempty(windows) && unsupported("no enabled analysis window")

    outblk = match(r"<output\s+path=[^>]*>(.*?)</output>"s, s)
    fields = outblk === nothing ? String[] :
             [String(f[1]) for f in eachmatch(r"<field\s+name=\"([^\"]*)\"", outblk[1])]
    for f in fields
        f in SUPPORTED_FIELDS || unsupported("output field '$f'")
    end
    proj = match(r"<project\s+name=\"([^\"]*)\"", s)
    pname = proj === nothing ? "QDOASJulia" : String(proj[1])
    # mediate.c: the NetCDF group is the output's swathName, or else the project name
    ot = match(r"<output\s+(path=[^>]*)>", s)
    swath = ot === nothing ? "" : strip(get(attrs(ot[1]), "swathName", ""))

    ProjectSpec(interp == "spline" ? :spline : :linear,
                round(Int, getf(a, "gap", 10.0)), getf(a, "converge", 1e-4),
                round(Int, getf(a, "max_iterations", 0.0)), getf(a, "spike_tolerance", 999.9),
                round(Int, getf(m, "size")), getb(m, "revert"),
                get(m, "calib", ""), get(m, "dark", ""), get(m, "offset", ""),
                spectrum, spectra, windows, fields, get(m, "date", "MM/DD/YYYY"),
                pname, isempty(swath) ? pname : String(swath))
end

"Project output fields reproduced by write_netcdf; any other field is refused."
const SUPPORTED_FIELDS = ("name", "date", "time", "rms", "chi", "iter_number", "error_flag", "residual_spectrum")

"A copy of `p` with some fields replaced, e.g. `respec(p; spectrum=path)`."
respec(p::ProjectSpec; kw...) =
    ProjectSpec((haskey(kw, f) ? kw[f] : getfield(p, f) for f in fieldnames(ProjectSpec))...)

"A copy of analysis window `w` with some fields replaced, e.g. `rewindow(w; lmin=300.0)`."
rewindow(w::WindowSpec; kw...) =
    WindowSpec((haskey(kw, f) ? kw[f] : getfield(w, f) for f in fieldnames(WindowSpec))...)

# =============================================================================
# The project's spectra (QDOAS raw_spectra tree)
# =============================================================================

"Shell-style file pattern (`*`, `?`) as a case-insensitive regex."
function glob_regex(pat::AbstractString)
    b = IOBuffer()
    for c in pat
        if c == '*'
            print(b, ".*")
        elseif c == '?'
            print(b, '.')
        elseif occursin(c, raw"\^$.|+()[]{}")
            print(b, '\\', c)
        else
            print(b, c)
        end
    end
    Regex("^" * String(take!(b)) * "\$", "i")
end

"QDOAS path placeholders: `%0`..`%9` in raw_spectra names expand to `<paths>` entries."
function path_table(s::AbstractString)
    t = Dict{String,String}()
    pb = match(r"<paths>(.*?)</paths>"s, s)
    pb === nothing && return t
    for m in eachmatch(r"<path\s+index=\"(\d)\"\s*>([^<]*)</path>", pb[1])
        t["%" * m[1]] = strip(m[2])
    end
    t
end

expand_path(p::AbstractString, t) = (length(p) >= 2 && haskey(t, p[1:2])) ? t[p[1:2]] * p[3:end] : String(p)

"""
Files listed by a project's `<raw_spectra>`: `<file name=...>` entries as given, and
`<directory name=... filters=... recursive=...>` entries expanded (filters are
shell patterns separated by `;`, `,` or spaces; matching ignores case), in order.
Disabled entries and folders are skipped.
"""
function expand_raw_spectra(s::AbstractString)
    rb = match(r"<raw_spectra>(.*?)</raw_spectra>"s, s)
    rb === nothing && return String[]
    body = replace(rb[1], r"<folder\b[^>]*disabled?=\"true\"[^>]*>.*?</folder>"s => "")
    pt = path_table(s)
    files = String[]
    for m in eachmatch(r"<(directory|file)\b([^>]*)>", body)
        a = attrs(m[2])
        (getb(a, "disabled") || getb(a, "disable")) && continue
        name = expand_path(get(a, "name", ""), pt)
        isempty(name) && continue
        if m[1] == "file"
            push!(files, name)
            continue
        end
        isdir(name) || continue
        pats = [glob_regex(f) for f in split(get(a, "filters", "*"), r"[;,\s]+"; keepempty=false)]
        isempty(pats) && push!(pats, glob_regex("*"))
        found = String[]
        if getb(a, "recursive")
            for (root, _, fs) in walkdir(name), f in fs
                any(r -> occursin(r, f), pats) && push!(found, joinpath(root, f))
            end
        else
            for f in readdir(name)
                path = joinpath(name, f)
                isfile(path) && any(r -> occursin(r, f), pats) && push!(found, path)
            end
        end
        append!(files, sort(found))
    end
    files
end

"""
    project_spectra(p::ProjectSpec) / project_spectra(xml_path)

The spectra a QDOAS project lists in its raw_spectra tree, expanded to files, minus
the project's dark, offset and calibration files.
"""
project_spectra(p::ProjectSpec) = p.spectra
project_spectra(xml_path::AbstractString) = parse_config(xml_path).spectra
