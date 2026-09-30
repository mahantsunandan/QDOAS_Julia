#!/usr/bin/env julia
# qdoasjl - command-line QDOAS analysis with QDOASJulia.
# Copyright (c) 2026 Sunandan Mahant <sunandanmahant@outlook.com>; BSD-3-Clause, see LICENSE.
#
# Usage (from anywhere; -t auto fits spectra in parallel):
#   julia --project=/path/to/QDOAS_Julia -t auto /path/to/QDOAS_Julia/bin/qdoasjl.jl -c project.xml
# Run with -h for all options.

using QDOASJulia
exit(QDOASJulia.main(ARGS))
