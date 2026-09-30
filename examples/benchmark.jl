# Speed of QDOASJulia on the synthetic project: spectra per second on one thread and on
# all threads Julia was started with.
#   julia --project=/path/to/QDOAS_Julia -t auto examples/benchmark.jl [n_spectra]
# Optionally compare with QDOAS:  QDOAS_DOAS_CL=/path/to/doas_cl julia ... benchmark.jl
# Copyright (c) 2026 Sunandan Mahant <sunandanmahant@outlook.com>; BSD-3-Clause, see LICENSE.

using QDOASJulia, Printf, Statistics
include(joinpath(@__DIR__, "synthetic_data.jl"))

n = isempty(ARGS) ? 200 : parse(Int, ARGS[1])
dir = mktempdir()
syn = make_synthetic(dir; nspec=n)
p = parse_config(syn.project)
analyze(p; spectrum=p.spectra[1])                         # compile first

per = [@elapsed(analyze(p; spectrum=f)) for f in p.spectra[1:min(n, 50)]]
t1 = @elapsed analyze_spectra(p; threads=false)
tn = @elapsed analyze_spectra(p; threads=true)
@printf("%d spectra, 2 analysis windows each (%s)\n", n, Sys.cpu_info()[1].model)
@printf("  one spectrum:  median %.1f ms\n", 1000 * median(per))
@printf("  1 thread:      %.2f s  (%.0f spectra/s)\n", t1, n / t1)
@printf("  %d threads:    %.2f s  (%.0f spectra/s)\n", Threads.nthreads(), tn, n / tn)

if haskey(ENV, "QDOAS_DOAS_CL")
    xml = read(syn.project, String)
    f = p.spectra[1]
    s = replace(xml, r"<output\s+path=\"[^\"]*\"" => "<output path=\"$(joinpath(dir, "q.nc"))\"")
    s = replace(s, r"<raw_spectra>.*?</raw_spectra>"s => "<raw_spectra><directory name=\"$(dirname(f))\" filters=\"$(basename(f))\" recursive=\"false\" /></raw_spectra>")
    cfg = joinpath(dir, "q.xml"); write(cfg, s)
    tq = @elapsed run(pipeline(`$(ENV["QDOAS_DOAS_CL"]) -c $cfg -a $(p.project_name)`; stdout=devnull, stderr=devnull))
    @printf("  QDOAS doas_cl, one spectrum per run: %.2f s\n", tq)
end
rm(dir; recursive=true, force=true)
