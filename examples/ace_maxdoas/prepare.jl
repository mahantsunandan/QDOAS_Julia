# Prepares the real-data example: MAX-DOAS spectra measured on the Antarctic
# Circumnavigation Expedition (ACE), analysed with public cross sections.
#
#   julia --project=/path/to/QDOAS_Julia examples/ace_maxdoas/prepare.jl
#
# The spectra are in data/ (from Zenodo, CC BY 4.0; see README.md). This script
# downloads the cross sections and the solar spectrum from their public sources, and
# writes into work/:
#
#   * calibration: the wavelength calibration and slit width of the instrument, found by
#     fitting the high-resolution solar spectrum to the noon zenith spectrum (as QDOAS's
#     "Kurucz" calibration does);
#   * reference.ref: the noon zenith spectrum on that calibration (the Fraunhofer reference);
#   * cross sections convolved with the instrument's slit function, and a Ring spectrum
#     computed from the solar spectrum with QDOAS's Ring algorithm;
#   * ace_maxdoas.xml: a QDOAS project using all of it, which QDOAS itself also runs.
#
# Needs internet access once (about 7 MB); the downloads are kept in work/downloads/.
# Copyright (c) 2026 Sunandan Mahant <sunandanmahant@outlook.com>; BSD-3-Clause, see LICENSE.
# The Ring algorithm is QDOAS's (Copyright (C) 1994-2025 BIRA-IASB and S[&]T, BSD-3-Clause,
# see NOTICE.md).

using QDOASJulia, Downloads, LinearAlgebra, Printf

const HERE = @__DIR__
const DATA = joinpath(HERE, "data")
const WORK = get(ENV, "QDOASJL_ACE_WORK", joinpath(HERE, "work"))
const DOWNLOADS = joinpath(WORK, "downloads")
include(joinpath(HERE, "raman_tables.jl"))
include(joinpath(HERE, "..", "project_template.jl"))

# -----------------------------------------------------------------------------
# public sources
# -----------------------------------------------------------------------------
const MAINZ = "https://uv-vis-spectral-atlas-mainz.org/uvvis_data/cross_sections/"

"""
Each cross section: its symbol, where it comes from, whether its wavelengths are in
vacuum (else in standard air) and the reference to cite. The analysis grid is in vacuum
wavelengths, because the calibration is made against the (vacuum) solar spectrum.
"""
const CROSS_SECTIONS = [
    (sym="NO2", file="no2_vandaele1998_294K.txt", vacuum=true,
     url=MAINZ * "Nitrogen%20oxides/NO2_Vandaele(1998)_294K_238-667nm.txt",
     cite="Vandaele, A. C. et al. (1998), J. Quant. Spectrosc. Radiat. Transfer 59, 171-184, doi:10.1016/S0022-4073(97)00168-4 (294 K)"),
    (sym="O3", file="o3_serdyuchenko2014_223K.txt", vacuum=true,
     url=MAINZ * "Ozone/O3_Serdyuchenko(2014)_223K_213-1100nm(2013%20version).txt",
     cite="Serdyuchenko, A. et al. (2014), Atmos. Meas. Tech. 7, 625-636, doi:10.5194/amt-7-625-2014 (223 K)"),
    (sym="O4", file="o4_thalman2013_293K.txt", vacuum=true,
     url=MAINZ * "Oxygen/O4_ThalmanVolkamer(2013)_293K_335.749-600.802nm.txt",
     cite="Thalman, R. and Volkamer, R. (2013), Phys. Chem. Chem. Phys. 15, 15371-15381, doi:10.1039/C3CP50968K (293 K)"),
    (sym="BrO", file="bro_fleischmann2004_223K.txt", vacuum=true,
     url=MAINZ * "Halogen%20oxides/Br%20oxides/BrO_Fleischmann(2004)_223K_300-385nm.txt",
     cite="Fleischmann, O. C. et al. (2004), J. Photochem. Photobiol. A 168, 117-132, doi:10.1016/j.jphotochem.2004.03.026 (223 K)"),
    (sym="HCHO", file="hcho_meller2000_298K.txt", vacuum=false,
     url=MAINZ * "Organics%20(carbonyls)/Aldehydes(aliphatic)/CH2O_MellerMoortgat(2000)_298K_224.56-376.00nm(0.01nm).txt",
     cite="Meller, R. and Moortgat, G. K. (2000), J. Geophys. Res. 105, 7089-7101, doi:10.1029/1999JD901074 (298 K)"),
]
const SOLAR = (file="sao2010.solref.converted", vacuum=true,
               url="https://www.cfa.harvard.edu/atmosphere/links/sao2010.solref.converted",
               cite="Chance, K. and Kurucz, R. L. (2010), J. Quant. Spectrosc. Radiat. Transfer 111, 1289-1295, doi:10.1016/j.jqsrt.2010.01.036")

function fetch(url, name)
    path = joinpath(DOWNLOADS, name)
    if !isfile(path)
        println("  downloading ", name)
        tmp = path * ".part"
        Downloads.download(url, tmp)
        mv(tmp, path; force=true)
    end
    path
end

"Two numeric columns (wavelength, value) of a text file; other lines are skipped."
function read_columns(path; col=2)
    x = Float64[]; y = Float64[]
    for l in eachline(path)
        f = split(l)
        length(f) >= col || continue
        a = tryparse(Float64, f[1]); b = tryparse(Float64, f[col])
        (a === nothing || b === nothing) && continue
        push!(x, a); push!(y, b)
    end
    p = sortperm(x)
    x[p], y[p]
end

"Refractive index of standard air (Edlén 1966, revised by Birch and Downs 1994); λ in nm."
air_index(λ) = (σ2 = (1e3 / λ)^2; 1 + 1e-8 * (8342.54 + 2406147 / (130 - σ2) + 15998 / (38.9 - σ2)))
air_to_vacuum(λ) = (v = λ; for _ in 1:5; v = λ * air_index(v); end; v)

# -----------------------------------------------------------------------------
# spectra
# -----------------------------------------------------------------------------
"Counts and header of an MFC STD file."
function read_std(path)
    lines = readlines(path)
    n = parse(Int, strip(lines[3]))
    counts = [parse(Float64, strip(lines[3+i])) for i in 1:n]
    counts, lines[4+n:end]
end

# -----------------------------------------------------------------------------
# slit function (Gaussian) and convolution
# -----------------------------------------------------------------------------
"""
Convolution of the high-resolution `(x, y)` with a Gaussian slit of full width at half
maximum `fwhm(λ)` nm, evaluated at the wavelengths `at`.
"""
function convolve(x, y, at, fwhm)
    out = similar(at, Float64)
    for (i, λ) in enumerate(at)
        s = fwhm(λ) / (2 * sqrt(2 * log(2)))
        lo = searchsortedfirst(x, λ - 5s); hi = searchsortedlast(x, λ + 5s)
        num = 0.0; den = 0.0
        for j in max(lo, 2):min(hi, length(x) - 1)
            g = exp(-0.5 * ((x[j] - λ) / s)^2) * (x[j+1] - x[j-1])
            num += g * y[j]; den += g
        end
        out[i] = den > 0 ? num / den : NaN
    end
    out
end

# -----------------------------------------------------------------------------
# Ring spectrum: QDOAS's Ring tool (mediate_xsconv.c mediateRingCalculate and
# ring.c raman_convolution, after Chance and Spurr 1997)
# -----------------------------------------------------------------------------
function raman_lines(temp)
    c2 = 1.438769; emult = -c2 / temp
    qn2 = sum((N2STAT_1[i] * 2 + 1) * N2STAT_2[i] * exp(emult * N2STAT_3[i]) for i in eachindex(N2STAT_1))
    n2 = [256 * π^5 * 0.79 / 27 * (N2DEG[i] * 2 + 1) * N2NUC[i] * exp(emult * N2TERM[i]) / qn2 * N2PLACTEL[i]
          for i in eachindex(N2TERM)]
    qo2 = sum((O2STAT_1[i] * 2 + 1) * exp(emult * O2STAT_2[i]) for i in eachindex(O2STAT_1))
    o2 = [256 * π^5 * 0.21 / 27 * (O2DEG[i] * 2 + 1) * exp(emult * O2TERM[i]) / qo2 * O2PLACTEL[i]
          for i in eachindex(O2TERM)]
    n2, o2
end

"""
Ring spectrum on `at`: the solar spectrum convolved with the slit, then with the
rotational Raman lines of N2 and O2 (normalised), divided by the convolved solar spectrum.
"""
function ring_spectrum(sλ, sy, at, fwhm; temp=250.0)
    keep = (sλ .> at[1] - 5) .& (sλ .< at[end] + 5)
    λ = sλ[keep]
    sol = convolve(sλ, sy, λ, fwhm)                    # solar spectrum at the instrument's resolution
    d2 = QDOASJulia.spline_deriv2(λ, sol)
    n2, o2 = raman_lines(temp)
    raman = similar(λ)
    for (i, l) in enumerate(λ)
        ν = 1e7 / l
        σsq = 1e6 / l^2
        γn2 = (-0.601466 + 238.557 / (186.099 - σsq))^2
        γo2 = (0.07149 + 45.9364 / (48.2716 - σsq))^2
        acc = 0.0; tot = 0.0
        for (w, pos, γ) in ((n2, N2POS, γn2), (o2, O2POS, γo2))
            for j in eachindex(w)
                νp = ν + pos[j]
                xsec = w[j] * νp^4 * γ
                tot += xsec
                acc += QDOASJulia.spline_at(λ, sol, d2, 1e7 / νp, true) * xsec
            end
        end
        raman[i] = acc / tot
    end
    r2 = QDOASJulia.spline_deriv2(λ, raman)
    [(r = QDOASJulia.spline_at(λ, raman, r2, a, true); s = QDOASJulia.spline_at(λ, sol, d2, a, true);
      r > 0 && s > 0 ? r / s : 0.0) for a in at]
end

# -----------------------------------------------------------------------------
# wavelength calibration against the solar spectrum
# -----------------------------------------------------------------------------
"""
Fits, in sub-windows of the noon zenith spectrum, a wavelength shift and the width of a
Gaussian slit: ln(measured) = ln(solar ⊗ slit)(λ + shift) + polynomial + O3 + Ring.
Returns the sub-window centres, shifts and widths.
"""
function calibrate(λ, counts, sλ, sy, o3; windows, ring=nothing)
    centres = Float64[]; shifts = Float64[]; widths = Float64[]
    for (a, b) in windows
        idx = findall(x -> a <= x <= b, λ)
        x = λ[idx]; lny = log.(counts[idx])
        t = (x .- (a + b) / 2) ./ ((b - a) / 2)
        extra = Vector{Vector{Float64}}()
        push!(extra, o3[idx])
        ring === nothing || push!(extra, ring[idx])
        function misfit(δ, w)
            m = log.(convolve(sλ, sy, x .+ δ, _ -> w))
            A = hcat([t .^ k for k in 0:3]..., extra...)
            r = (lny .- m) - A * (A \ (lny .- m))
            sum(abs2, r)
        end
        best = (Inf, 0.0, 0.5)
        for w in 0.30:0.05:1.20, δ in -0.40:0.02:0.40
            v = misfit(δ, w); v < best[1] && (best = (v, δ, w))
        end
        for (dδ, dw) in ((0.005, 0.01), (0.001, 0.002), (0.0002, 0.0005))
            _, δ0, w0 = best
            for w in w0-4dw:dw:w0+4dw, δ in δ0-4dδ:dδ:δ0+4dδ
                w > 0.05 || continue
                v = misfit(δ, w); v < best[1] && (best = (v, δ, w))
            end
        end
        push!(centres, (a + b) / 2); push!(shifts, best[2]); push!(widths, best[3])
    end
    centres, shifts, widths
end

polyfit(x, y, order) = (x0 = sum(x) / length(x); c = hcat([(x .- x0) .^ k for k in 0:order]...) \ y; v -> sum(c[k+1] * (v - x0)^k for k in 0:order))

function write_two_columns(path, x, y; header="")
    open(path, "w") do io
        isempty(header) || print(io, header)
        for (a, b) in zip(x, y)
            @printf(io, "%.6f  %.8e\n", a, b)
        end
    end
    path
end

# -----------------------------------------------------------------------------
function main()
    mkpath(DOWNLOADS); mkpath(joinpath(WORK, "cross"))
    println("QDOASJulia ACE MAX-DOAS example: preparing ", WORK)

    # instrument calibration (Hg-Ne lines, from the data set) and the noon zenith spectrum
    λinst = parse.(Float64, readlines(joinpath(DATA, "calibration", "ace_uv_instrument.clb")))
    refstd = only(filter(f -> endswith(f, ".STD"), readdir(joinpath(DATA, "reference"); join=true)))
    refcounts, _ = read_std(refstd)
    length(refcounts) == length(λinst) || error("reference and calibration sizes differ")

    sλ, sy = read_columns(fetch(SOLAR.url, SOLAR.file))
    SOLAR.vacuum || (sλ = air_to_vacuum.(sλ))
    xs = Dict{String,Tuple{Vector{Float64},Vector{Float64}}}()
    for c in CROSS_SECTIONS
        x, y = read_columns(fetch(c.url, c.file))
        c.vacuum || (x = air_to_vacuum.(x))
        # some data sets have gaps between bands: keep the continuous part around 350 nm
        cuts = [0; findall(>(1.0), diff(x)); length(x)]
        k = findfirst(i -> x[cuts[i]+1] <= 350 <= x[cuts[i+1]], 1:length(cuts)-1)
        k === nothing && error("$(c.sym): no data around 350 nm")
        xs[c.sym] = (x[cuts[k]+1:cuts[k+1]], y[cuts[k]+1:cuts[k+1]])
    end

    # 1. calibration: shift and slit width in 8 sub-windows, then smooth functions of λ
    println("  calibrating the wavelengths and the slit width against the solar spectrum")
    wins = [(318.0 + 10k, 328.0 + 10k) for k in 0:7]
    o3first = convolve(xs["O3"]..., λinst, _ -> 0.55)
    c, sh, fw = calibrate(λinst, refcounts, sλ, sy, o3first; windows=wins)
    shift = polyfit(c, sh, 2); fwhm0 = polyfit(c, fw, 1)
    # second pass, with a Ring spectrum at the first-pass resolution
    ring0 = ring_spectrum(sλ, sy, λinst .+ shift.(λinst), fwhm0)
    c, sh, fw = calibrate(λinst, refcounts, sλ, sy, convolve(xs["O3"]..., λinst .+ shift.(λinst), fwhm0);
                          windows=wins, ring=ring0)
    shift = polyfit(c, sh, 2); fwhm = polyfit(c, fw, 1)
    for k in eachindex(c)
        @printf("    %5.1f nm: shift %+.4f nm (smooth %+.4f), slit FWHM %.3f nm (smooth %.3f)\n",
                c[k], sh[k], shift(c[k]), fw[k], fwhm(c[k]))
    end
    λ = λinst .+ shift.(λinst)

    calib = joinpath(WORK, "calibration.clb")
    open(io -> foreach(x -> @printf(io, "%.6f\n", x), λ), calib, "w")
    reference = write_two_columns(joinpath(WORK, "reference.ref"), λ, refcounts)

    # 2. cross sections at the instrument's resolution, on the calibrated grid
    println("  convolving the cross sections")
    files = Dict{String,String}()
    for c in CROSS_SECTIONS
        x, y = xs[c.sym]
        keep = findall(v -> x[1] + 1.5 <= v <= x[end] - 1.5, λ)
        files[c.sym] = write_two_columns(joinpath(WORK, "cross", c.sym * ".xs"), λ[keep], convolve(x, y, λ[keep], fwhm);
            header="; $(c.sym): $(c.cite)\n; convolved with a Gaussian slit (FWHM $(round(fwhm(340); digits=3))-$(round(fwhm(390); digits=3)) nm), vacuum wavelengths\n")
    end
    println("  computing the Ring spectrum")
    files["Ring"] = write_two_columns(joinpath(WORK, "cross", "Ring.xs"), λ, ring_spectrum(sλ, sy, λ, fwhm);
        header="; Ring spectrum from the solar spectrum of $(SOLAR.cite),\n; QDOAS Ring algorithm (Chance and Spurr 1997), 250 K, Gaussian slit\n")

    # 3. the QDOAS project
    project = joinpath(WORK, "ace_maxdoas.xml")
    write(project, ace_project(; calib=calib, reference=reference, files=files,
                               spectra_dir=joinpath(DATA, "spectra"), output=joinpath(WORK, "qdoas_results.nc")))
    println("  wrote ", project)
    project
end

"The QDOAS project of the example: an NO2 and an O4 analysis window."
function ace_project(; calib, reference, files, spectra_dir, output)
    no2 = window_xml("NO2", 338.0, 370.0;
        reference=reference,
        xs=[("NO2", files["NO2"]), ("O3", files["O3"]), ("O4", files["O4"]), ("BrO", files["BrO"]),
            ("HCHO", files["HCHO"]), ("Ring", files["Ring"])],
        poly=5, linear_offset=1,
        shifts=[(["Spectrum"], true, true), (["Ref"], false, false),
                (["NO2", "O3", "O4", "BrO", "HCHO", "Ring"], false, false)])
    o4 = window_xml("O4", 352.0, 384.0;
        reference=reference,
        xs=[("O4", files["O4"]), ("NO2", files["NO2"]), ("O3", files["O3"]), ("BrO", files["BrO"]),
            ("Ring", files["Ring"])],
        poly=5, linear_offset=1,
        shifts=[(["Spectrum"], true, true), (["Ref"], false, false),
                (["O4", "NO2", "O3", "BrO", "Ring"], false, false)])
    project_xml(; name="ACE MAX-DOAS", npix=1340, calib=calib, windows=[no2, o4],
                spectra_dir=spectra_dir, filter="*.STD", output=output,
                symbols=["NO2", "O3", "O4", "BrO", "HCHO", "Ring"])
end

if abspath(PROGRAM_FILE) == @__FILE__
    main()
end
