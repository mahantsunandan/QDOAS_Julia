# This file is part of QDOASJulia, a Julia port of the QDOAS DOAS analysis core.
# Copyright (c) 2026 Sunandan Mahant <sunandanmahant@outlook.com>
# Derived from QDOAS, Copyright (C) 1994-2025 BIRA-IASB and S[&]T (BSD-3-Clause).
# See LICENSE and NOTICE.md.

# =============================================================================
# MFC STD reading (mfc-read.c MFC_ReadRecordStd)
# =============================================================================

mutable struct MfcState               # QDOAS keeps these in a global record struct
    nsomme::Int
    tint::Float64
    total_acq::Float64
end
MfcState() = MfcState(0, 0.0, 0.0)

struct MfcRecord
    spe::Vector{Float64}
    noscans::Int
    int_time::Float32
    name::String                       # pRecord->Nom (first 20 characters)
    date::NTuple{3,Int}                # (year, month, day)
    time::NTuple{3,Int}                # mid-exposure (hour, min, sec)
    # header information that does not enter the fit (NaN when the file has none)
    elevation::Float64                 # viewing elevation angle, degrees
    azimuth::Float64                   # viewing azimuth angle, degrees
    latitude::Float64
    longitude::Float64
end

"Date and mid-exposure time as MFC_ReadRecordStd derives them."
function header_datetime(dline, t1, t2, date_format)
    iday = imon = iyear = 0; sep = 0
    for ch in date_format
        if ch in ('Y', 'y'); iyear = sep
        elseif ch in ('M', 'm'); imon = sep
        elseif ch in ('D', 'd'); iday = sep
        else sep += 1
        end
    end
    nums = [parse(Int, x.match) for x in eachmatch(r"\d+", dline)]
    length(nums) >= 3 || (nums = [0, 0, 0])
    day, mon, year = nums[iday+1], nums[imon+1], nums[iyear+1]
    year < 30 ? (year += 2000) : year < 130 ? (year += 1900) : year < 1930 && (year += 100)
    hms(t) = (v = [parse(Int, x.match) for x in eachmatch(r"\d+", t)]; length(v) >= 3 ? v[1:3] : [0, 0, 0])
    a, b = hms(t1), hms(t2)
    n1 = a[1] * 3600 + a[2] * 60 + a[3]
    n2 = b[1] * 3600 + b[2] * 60 + b[3]
    n2 < n1 && (n2 += 86400)
    nsec = (n1 + n2) ÷ 2
    (year, mon, day), (nsec ÷ 3600, (nsec % 3600) ÷ 60, (nsec % 3600) % 60)
end

function read_mfc_std(path, n_wavel, st::MfcState; date_format="MM/DD/YYYY")
    lines = readlines(path)
    spe = zeros(n_wavel)
    length(lines) >= 3 || throw(EngineError("short MFC file $path"))
    pixfin = parse(Int, split(strip(lines[3]))[1])
    li = 3
    for i in 1:pixfin
        li += 1
        v = tryparse(Float64, split(strip(lines[li]))[1])
        i <= n_wavel && v !== nothing && (spe[i] = v)
    end
    # specname, spectroname, scan_dev, date, start, end, 2 floats (8 lines)
    hdr(k) = li + k <= length(lines) ? strip(lines[li+k]) : ""
    name = first(hdr(1), 20)
    date, tmid = header_datetime(hdr(4), hdr(5), hdr(6), date_format)
    li += 8
    rest = lines[li+1:end]
    # fscanf "SCANS %d" / "int_TIME %lf" are literal, case-sensitive matches that
    # stop the sequence at the first mismatch - mirror that.
    j = 1
    if j <= length(rest) && (m = match(r"^SCANS\s+(-?\d+)", rest[j])) !== nothing
        st.nsomme = parse(Int, m[1]); j += 1
        if j <= length(rest) && (m2 = match(r"^int_TIME\s+(\S+)", rest[j])) !== nothing
            st.total_acq = parse(Float64, m2[1])
        end
    end
    elev = azim = lat = lon = NaN
    num(v) = something(tryparse(Float64, v), NaN)
    for l in rest
        if (mm = match(r"^(LONGITUDE|LATITUDE)\s+(\S+)", l)) !== nothing
            mm[1] == "LONGITUDE" ? (lon = num(mm[2])) : (lat = num(mm[2]))
            continue
        end
        occursin('=', l) || continue
        mm = match(r"^\s*(\S+)\s*=\s*(\S+)", l)
        mm === nothing && continue
        k, v = lowercase(mm[1]), mm[2]
        if k == "exposuretime"
            st.tint = something(tryparse(Float64, v), 0.0) * 0.001
        elseif k == "numscans"
            st.nsomme = something(tryparse(Int, v), 0)
        elseif k == "elevationangle"
            elev = num(v)
        elseif k == "azimuthangle"
            azim = num(v)
        elseif k == "latitude"
            lat = num(v)
        elseif k == "longitude"
            lon = num(v)
        end
    end
    # mfc-read.c: an elevation above 100 degrees looks backwards
    if elev > 100
        elev = 180 - elev
        isnan(azim) || (azim = mod(azim + 180, 360))
    end
    if st.tint < 1e-3 && st.total_acq > 1e-3
        st.tint = st.total_acq
    end
    MfcRecord(spe, st.nsomme, Float32(st.tint), name, date, tmid, elev, azim, lat, lon)
end

"Spectrum after QDOAS's offset and dark corrections (engine.c / mfc-read.c order)."
function load_spectrum(p::ProjectSpec)
    n = p.n_det
    st = MfcState()
    off = nothing
    if !isempty(p.offset)                       # MFC_LoadOffset: raw read
        off = read_mfc_std(p.offset, n, st)
    end
    drk = nothing
    if !isempty(p.dark)                         # MFC_LoadDark: offset removed from dark
        d = read_mfc_std(p.dark, n, st)
        v = copy(d.spe)
        if off !== nothing && off.noscans > 0
            for i in 1:n
                v[i] -= Float64(off.spe[i]) * d.noscans / off.noscans
            end
        end
        drk = MfcRecord(v, d.noscans, d.int_time, d.name, d.date, d.time, d.elevation, d.azimuth, d.latitude, d.longitude)
    end
    s = read_mfc_std(p.spectrum, n, st; date_format=p.date_format)
    spe = copy(s.spe)
    if off !== nothing && off.noscans > 0
        for i in 1:n
            spe[i] -= Float64(off.spe[i]) * s.noscans / off.noscans
        end
    end
    if drk !== nothing && drk.int_time != 0f0
        den = Float64(drk.int_time * Float32(drk.noscans))
        for i in 1:n
            spe[i] -= Float64(s.noscans) * drk.spe[i] * Float64(s.int_time) / den
        end
    end
    p.revert && reverse!(spe)
    spe, s
end

"AnalyseLoadVector for a two-column reference file."
function load_two_columns(path, n)
    lam = zeros(n); v = zeros(n)
    i = 0
    for l in eachline(path)
        (occursin(';', l) || occursin('*', l) || occursin('#', l)) && continue
        f = split(strip(l))
        length(f) >= 2 || continue
        i += 1
        i > n && break
        lam[i] = parse(Float64, f[1]); v[i] = parse(Float64, f[2])
    end
    i < n && throw(EngineError("reference $path has $i lines, expected $n"))
    lam, v
end

# Parsed cross sections and references, shared across calls (a batch analyses many
# spectra with the same windows). Keyed on path + size + mtime so an edited file is
# re-read.
const FILE_CACHE = Dict{Any,Any}()
const FILE_CACHE_LOCK = ReentrantLock()
const FILE_CACHE_MAX = 4000

function cached(f, key)
    st = stat(key[1])
    k = (key..., st.size, st.mtime)
    lock(FILE_CACHE_LOCK) do
        v = get(FILE_CACHE, k, nothing)
        v === nothing || return v
        length(FILE_CACHE) >= FILE_CACHE_MAX && empty!(FILE_CACHE)
        v = f()
        FILE_CACHE[k] = v
        v
    end
end

"MATRIX_Load (no range cut) + optional second derivatives of column 2."
function load_xs(path)
    rows = Vector{Vector{Float64}}()
    for l in eachline(path)
        s = strip(l)
        (isempty(s) || s[1] in (';', '#', '*')) && continue
        f = split(s)
        push!(rows, parse.(Float64, f))
    end
    isempty(rows) && throw(EngineError("empty cross section $path"))
    nc = length(rows[1])
    all(length(r) == nc for r in rows) || throw(EngineError("ragged cross section $path"))
    lam = [r[1] for r in rows]
    val = [r[2] for r in rows]
    if length(lam) > 1 && lam[1] > lam[2]
        reverse!(lam); reverse!(val)
    end
    lam, val, nc
end
