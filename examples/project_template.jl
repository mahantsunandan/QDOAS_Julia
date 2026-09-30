# Writes QDOAS project files (.xml) in the layout the QDOAS GUI saves, for the examples.
# Only the settings QDOASJulia supports are written; QDOAS itself opens and runs the files.
# Copyright (c) 2026 Sunandan Mahant <sunandanmahant@outlook.com>; BSD-3-Clause, see LICENSE.

using Printf

xmlesc(s) = replace(String(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")

cross_xml(sym, file) = """        <cross_section sym="$(xmlesc(sym))" ortho="None" cstype="interp" amftype="none" fit="true" filter="true" cstrncc="false" ccfit="true" icc="0.000" dcc="0.001" ccio="0.000" csfile="$(xmlesc(file))" amffile="" />\n"""
output_xml(sym) = """        <output sym="$(xmlesc(sym))" amf="false" scol="true" serr="true" sfact="1.000" rescol="0.000000e+000" vcol="false" verr="false" vfact="1.000" />\n"""

"""
One shift/stretch row: `syms` share a shift (fitted when `fit`), and a first-order
stretch when `stretch`.
"""
shift_xml(syms, fit=false, stretch=false; init=0.0) =
    """        <shift_stretch shfit="$(fit)" stfit="$(stretch ? "1st" : "none")" scfit="none" shstr="true" ststr="true" scstr="false" errstr="true" shini="$(@sprintf("%.3f", init))" stini="0.000" stini2="0.000" scini="0.000" scini2="0.000" shdel="0.0010" stdel="0.0010" stdel2="0.0010" scdel="0.0010" scdel2="0.0010" shmin="0.000" shmax="0.000" >\n""" *
    join("          <symbol name=\"$(xmlesc(s))\" />\n" for s in syms) * "        </shift_stretch>\n"

"""
    window_xml(name, lmin, lmax; reference, xs, shifts, poly=3, linear_offset=-1, offset=false)

An analysis window: `xs` is a list of (symbol, file); `shifts` a list of (symbols, fit)
or (symbols, fit, stretch); `poly` the polynomial order; `linear_offset` the order of a
linear offset (-1 for none); `offset` fits a non-linear constant offset instead.
"""
function window_xml(name, lmin, lmax; reference, xs, shifts, poly=3, linear_offset=-1, offset=false)
    cross = join(cross_xml(s, f) for (s, f) in xs)
    outs = join(output_xml(s) for (s, _) in xs)
    o = offset ? "true" : "false"
    off = linear_offset < 0 ? """offpoly="none" offbase="none" offfit="false" offerr="false\"""" :
                              """offpoly="$linear_offset" offbase="none" offfit="true" offerr="true\""""
    """
    <analysis_window name="$(xmlesc(name))" disable="false" kurucz="none" refsel="file" min="$(@sprintf("%.3f", lmin))" max="$(@sprintf("%.3f", lmax))" resol_fwhm="0.500" >
      <display spectrum="true" poly="true" fits="true" residual="true" predef="true" ratio="true" />
      <files saveresiduals="true" refone="$(xmlesc(reference))" reftwo="" residual="" szacenter="0.000" szadelta="0.000" scanmode="after" minlon="0.000" maxlon="0.000" minlat="0.000" maxlat="0.000" refns="1" cloudfmin="0.000" cloudfmax="1.000" maxdoasrefmode="sza" east="false" center="false" west="false" backscan="false" />
      <cross_sections>
$(cross)      </cross_sections>
      <linear xpoly="$poly" xbase="none" xfit="true" xerr="true" xinvpoly="none" xinvbase="none" xinvfit="false" xinverr="false" $off />
      <nonlinear solfit="false" solinit="0.000" soldelt="0.001" solfstr="false" solestr="false"
                 o0fit="$o" o0init="0.000" o0delt="0.001" o0fstr="$o" o0estr="$o"
                 o1fit="false" o1init="0.000" o1delt="0.001" o1fstr="false" o1estr="false"
                 o2fit="false" o2init="0.000" o2delt="0.001" o2fstr="false" o2estr="false"
                 comfit="false" cominit="0.000" comdelt="0.001" comstr="false" comestr="false"
                 u1fit="false" u1init="0.000" u1delt="0.001" u1str="false" u1estr="false"
                 u2fit="false" u2init="0.000" u2delt="0.001" u2str="false" u2estr="false"
                 ramfit="false" raminit="0.000" ramdelt="0.000" ramstr="false" ramestr="false"
                 comfile="" u1file="" u2file="" ramfile="" />
      <shift_stretches>
$(join(shift_xml(s...) for s in shifts))      </shift_stretches>
      <gaps>
      </gaps>
      <outputs>
$(outs)      </outputs>
    </analysis_window>
"""
end

"""
    project_xml(; name, npix, calib, windows, spectra_dir, filter, output, symbols,
                dark="", offset="")

A QDOAS project for an MFC STD instrument with `npix` pixels, the analysis windows
`windows` (from `window_xml`) and the spectra `filter` in `spectra_dir`.
"""
function project_xml(; name, npix, calib, windows, spectra_dir, filter, output, symbols, dark="", offset="")
    syms = join("    <symbol name=\"$(xmlesc(s))\" descr=\"\" />\n" for s in symbols)
    """
<?xml version="1.0" encoding="UTF-8"?>
<qdoas>
  <paths>
  </paths>
  <symbols>
$(syms)  </symbols>
  <project name="$(xmlesc(name))" disable="false">
    <display spectra="true" data="true" calib="true" fits="true">
      <field name="name" />
      <field name="date" />
      <field name="starttime" />
      <field name="endtime" />
    </display>
    <selection>
      <sza min="0.000" max="0.000" delta="0.000" />
      <elevation min="0.000" max="0.000" tol="0.000" />
      <reference angle="90.000" tol="10.000" />
      <record min="0" max="0" />
      <cloud min="0.000" max="1.000" />
      <geolocation selected="none">
        <circle radius="0.000" long="0.000" lat="0.000" />
        <rectangle west="0.000" east="0.000" south="0.000" north="0.000" />
        <sites radius="0.000" />
      </geolocation>
    </selection>
    <analysis method="ODF" fit="none" unit="nm" interpolation="spline" gap="10" converge="0.0001" max_iterations="0" spike_tolerance="999.9" >
    </analysis>
    <lowpass_filter selected="none">
    </lowpass_filter>
    <highpass_filter selected="none">
    </highpass_filter>
    <calibration ref="" method="ODF">
      <line shape="none" lorentzorder="1" slfFile="" />
      <display spectra="true" fits="true" residual="true" shiftsfp="true" />
      <polynomial shift="3" sfp="3" />
      <window min="300.0" max="340.0" intervals="4" custom_windows="" division="contiguous" size="10.00" />
      <preshift calculate="false" min="-3.0" max="3.0" />
      <cross_sections>
      </cross_sections>
      <linear xpoly="2" xbase="none" xfit="false" xerr="false" offpoly="none" offfit="false" offerr="false" offizero="false" />
      <shift_stretches>
      </shift_stretches>
      <gaps>
      </gaps>
      <outputs>
      </outputs>
    </calibration>
    <undersampling ref="" method="file" shift="0.000000" />
    <instrumental format="mfcstd" site="No Site Specified">
      <mfcstd size="$npix" revert="false" straylight="false" date="MM/DD/YYYY" lambda_min="0" lambda_max="0" calib="$(xmlesc(calib))" instr="" dark="$(xmlesc(dark))" offset="$(xmlesc(offset))" />
    </instrumental>
    <slit ref="" fwhmcor="false">
      <slit_func type="none">
      </slit_func>
    </slit>
    <output path="$(xmlesc(output))" anlys="true" calib="false" ref="false" conf="false" dirs="true" file="true" success="false" flux="" cic=" " bandWidth="1.0" swathName="QDOAS Results" fileFormat=".nc">
      <field name="name" />
      <field name="date" />
      <field name="time" />
      <field name="rms" />
      <field name="chi" />
      <field name="iter_number" />
      <field name="error_flag" />
      <field name="residual_spectrum" />
    </output>
$(join(windows))    <raw_spectra>
      <directory name="$(xmlesc(spectra_dir))" filters="$(xmlesc(filter))" recursive="false" />
    </raw_spectra>
  </project>
</qdoas>
"""
end
