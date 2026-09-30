# QDOASJulia - a Julia port of the QDOAS DOAS analysis core.
# Copyright (c) 2026 Sunandan Mahant <sunandanmahant@outlook.com>
# Derived from QDOAS, Copyright (C) 1994-2025 BIRA-IASB and S[&]T (BSD-3-Clause).
# See LICENSE and NOTICE.md.

"""
    QDOASJulia

A Julia port of the spectral analysis core of QDOAS, the DOAS software of the Royal
Belgian Institute for Space Aeronomy (BIRA-IASB) and S[&]T
(<https://uv-vis.aeronomie.be/software/QDOAS/>). It reads QDOAS project files and
MFC STD spectra, performs QDOAS's optical-density fit (analysis method "ODF") and
returns - or writes, in QDOAS's NetCDF layout - slant column densities, their errors,
shifts, stretches, offsets and residuals that agree with QDOAS to floating-point
precision.

Supported (everything else raises `UnsupportedConfig` rather than being approximated):

  * optical-density fitting (`method="ODF"`), no fit weighting
  * MFC STD spectra; offset and dark correction; reference spectrum from a file
  * cross sections used as they are (`cstype="none"`) or interpolated (`"interp"`)
  * polynomial in (λ - λ0) of order 0..8; linear offset (radiance or reference
    normalised); non-linear offset of order 0..2
  * shift and stretch (1st and 2nd order) on the spectrum, the reference or groups of
    cross sections, fitted or fixed; gaps; cubic-spline or linear interpolation

Each routine mirrors the QDOAS C/C++ source it is named after, including the order
of operations where that affects rounding. QDOAS source files (engine/):

  mfc-read.c         MFC_ReadRecordStd, MFC_LoadOffset/Dark
  spline.c           SPLINE_Deriv2, SPLINE_Vector
  analyse.c          FNPixel, ANALYSE_SvdInit, ShiftVector, ANALYSE_Function,
                     ANALYSE_CurFitMethod, ANALYSE_Spectrum, ANALYSE_Load*
  curfit.c           Fchisq, CurfitMatinv, CurfitNumDeriv, Curfit
  linear_system.cpp  LINEAR_decompose / LINEAR_solve (DECOMP_EIGEN_QR)
  output*.c(pp)      the NetCDF layout

The fit code is unchanged between QDOAS 3.7.5, against whose `doas_cl` this port was
validated, and QDOAS 3.7.13.
"""
module QDOASJulia

using LinearAlgebra
using Printf
using NCDatasets
using HTTP
using JSON3
using Sockets

export UnsupportedConfig, EngineError,
       parse_config, project_spectra, analyze, analyze_config, analyze_spectra,
       write_netcdf, run_config, results_table, write_csv, print_summary, serve_gui

"Version of this package (kept in step with Project.toml)."
const VERSION_STRING = "0.1.0"

const EPSILON = 1.0e-6
const MAX_REPEAT_CURFIT = 3
const CURFIT_MAX_ITER = 100

"An option of the QDOAS project that this port does not implement (use QDOAS for it)."
struct UnsupportedConfig <: Exception
    msg::String
end
Base.showerror(io::IO, e::UnsupportedConfig) = print(io, "UnsupportedConfig: ", e.msg)

"A condition under which QDOAS itself would report an error for this window."
struct EngineError <: Exception
    msg::String
end
Base.showerror(io::IO, e::EngineError) = print(io, "EngineError: ", e.msg)

unsupported(msg) = throw(UnsupportedConfig(msg))

include("config.jl")      # QDOAS project files
include("numerics.jl")    # splines, pixel search, normalisation
include("spectra.jl")     # MFC STD spectra, references, cross sections
include("fit.jl")         # the fit: model function and Levenberg-Marquardt (Curfit)
include("results.jl")     # per-window results in QDOAS's conventions
include("analysis.jl")    # analyse a spectrum, or many in parallel
include("netcdf.jl")      # QDOAS-layout NetCDF output
include("table.jl")       # CSV summary, printed summaries
include("cli.jl")         # command-line interface (bin/qdoasjl.jl)
include("gui.jl")         # local web GUI

end # module
