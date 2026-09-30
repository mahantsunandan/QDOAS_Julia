# Real-data example: MAX-DOAS on the Antarctic Circumnavigation Expedition

This example analyses **real, publicly available** MAX-DOAS spectra with **public
laboratory cross sections**, in a QDOAS project that QDOAS itself also runs.

```bash
julia --project examples/ace_maxdoas/prepare.jl        # once; needs internet (about 7 MB)
julia --project -t auto examples/run_gui.jl ace         # the GUI on this project
julia --project -t auto bin/qdoasjl.jl -c examples/ace_maxdoas/work/ace_maxdoas.xml -o ace_results
```

## The spectra (`data/`)

The spectra were measured by the MAX-DOAS instrument of the Instituto de Química Física
Rocasolano (CSIC) on the research vessel *Akademik Tryoshnikov* during the Antarctic
Circumnavigation Expedition (ACE), and published by

> Benavent, N., Garcia-Nieto, D., Cuevas, C. A. and Saiz-Lopez, A. (2020). *Raw spectra
> measurements of scattered sunlight collected using a MAX-DOAS (Multi-Axis Differential
> Optical Absorption Spectroscopy) instrument in the austral summer of 2016/17 during the
> Antarctic Circumnavigation Expedition (ACE).* Version 1.0 [Data set]. Zenodo.
> <https://doi.org/10.5281/zenodo.3827443>

under the **Creative Commons Attribution 4.0 International license (CC BY 4.0,
<https://creativecommons.org/licenses/by/4.0/>)**. The data set's authors are not
associated with QDOASJulia and do not endorse it.

This folder holds a small part of that data set: the UV spectrometer (Princeton Instruments
SP500i with a PIXIS 400B CCD, 1340 pixels, 314.6–400.9 nm) on **7 April 2017**, when the
ship was in the Atlantic off Portugal (about 40°N, 12°W):

* `spectra/`: 144 spectra, one complete elevation scan per hour from 07:00 to 18:00 UTC,
  each scan at 12 viewing elevations (−2°, 0°, 1°, 2°, 3°, 4°, 6°, 10°, 15°, 30°, 70° and 90°);
* `reference/`: the zenith spectrum closest to local noon (12:51 UTC, solar zenith angle
  34.5°), used as the Fraunhofer reference;
* `calibration/ace_uv_instrument.clb`: the instrument's own wavelength calibration
  (from Hg–Ne lines, as published with every spectrum).

**Changes made to the published data** (as CC BY 4.0 asks us to state), all by
[`tools/fetch_ace_spectra.py`](tools/fetch_ace_spectra.py), which recreates this folder
from Zenodo:

* the 19 optical-fibre columns of each spectrum were added up into one spectrum; the counts
  are otherwise the published ones (offset and dark current had been subtracted by the
  instrument software);
* the spectra were written in the MFC STD text format that QDOAS reads, with the elevation
  angle, the solar zenith angle, the number of scans and the exposure time from the data
  set's `LiveInfo` files, and the ship's position from its GPS files; the last header line
  of each file names the original file;
* the wavelength column, identical in every file, was written once to the calibration file.

## What `prepare.jl` does (`work/`, not in the repository)

1. **Downloads** the cross sections from the MPI-Mainz UV/VIS Spectral Atlas (Keller-Rudek
   et al., 2013) and the solar spectrum of Chance and Kurucz (2010). They are not
   redistributed here; see the list below for whom to cite.
2. **Calibrates the wavelengths and the slit function**, as QDOAS's "Kurucz" calibration
   does: in eight 10 nm sub-windows from 318 to 398 nm it fits the high-resolution solar
   spectrum, convolved with a Gaussian slit, to the noon zenith spectrum (plus a polynomial,
   ozone and a Ring term), and keeps a smooth shift (2nd order in λ) and slit width (1st
   order). The instrument's calibration is off by +0.06 to +0.33 nm from the solar
   spectrum's vacuum wavelengths; the slit's full width at half maximum is 0.37 nm.
3. **Convolves each cross section** with that slit on the calibrated grid (air wavelengths
   converted to vacuum with Edlén's formula where a data set uses air), and computes a
   **Ring spectrum** from the solar spectrum with QDOAS's own Ring algorithm (rotational
   Raman scattering of N₂ and O₂ at 250 K after Chance and Spurr, 1997; the line tables in
   [`raman_tables.jl`](raman_tables.jl) are QDOAS's).
4. **Writes the QDOAS project** `work/ace_maxdoas.xml` with two analysis windows:

| window | interval | absorbers | polynomial, offset | shift and stretch |
|---|---|---|---|---|
| NO2 | 338–370 nm | NO₂, O₃, O₄, BrO, HCHO, Ring | order 5, linear offset of order 1 | on *Spectrum* |
| O4 | 352–384 nm | O₄, NO₂, O₃, BrO, Ring | order 5, linear offset of order 1 | on *Spectrum* |

The wavelength convention of the strong absorbers was checked on these spectra by fitting
each with a free shift of its own: O₄, O₃ and the Ring spectrum come out within 0.03 nm of
zero (the O₄ data turned out to be in vacuum wavelengths; assuming air would have shifted
them by 0.10 nm). NO₂, BrO and HCHO are too weak in these spectra to be checked this way;
their conventions are taken from the literature (vacuum, vacuum and air).

The results are **differential** slant columns relative to the noon zenith spectrum. O₄
grows strongly towards the horizon, as expected. NO₂ is close to zero around noon and
reaches about 1.5 × 10¹⁶ molecules cm⁻² at the large solar zenith angles of the early
morning and evening, most of it in the stratosphere: there is little NO₂ near the surface in
this marine air. This is
a demonstration set-up: a careful analysis would add an I₀ correction for ozone, several
ozone temperatures, a measured slit function and quality filtering (clouds, the −2° view of
the sea surface).

### Cross sections and solar spectrum (downloaded by `prepare.jl`)

| symbol | data set | cite |
|---|---|---|
| NO₂ | Vandaele et al. (1998), 294 K | J. Quant. Spectrosc. Radiat. Transfer 59, 171–184, doi:10.1016/S0022-4073(97)00168-4 |
| O₃ | Serdyuchenko et al. (2014), 223 K | Atmos. Meas. Tech. 7, 625–636, doi:10.5194/amt-7-625-2014 |
| O₄ | Thalman and Volkamer (2013), 293 K | Phys. Chem. Chem. Phys. 15, 15371–15381, doi:10.1039/C3CP50968K |
| BrO | Fleischmann et al. (2004), 223 K | J. Photochem. Photobiol. A 168, 117–132, doi:10.1016/j.jphotochem.2004.03.026 |
| HCHO | Meller and Moortgat (2000), 298 K | J. Geophys. Res. 105, 7089–7101, doi:10.1029/1999JD901074 |
| solar | Chance and Kurucz (2010) | J. Quant. Spectrosc. Radiat. Transfer 111, 1289–1295, doi:10.1016/j.jqsrt.2010.01.036 |

The cross sections come from the MPI-Mainz UV/VIS Spectral Atlas: Keller-Rudek, H.,
Moortgat, G. K., Sander, R. and Sörensen, R. (2013), Earth Syst. Sci. Data 5, 365–373,
doi:10.5194/essd-5-365-2013. The solar spectrum comes from the Harvard-Smithsonian Center
for Astrophysics (<https://www.cfa.harvard.edu/atmosphere/>).

## QDOAS and QDOASJulia on these spectra

QDOAS 3.7.5 (`doas_cl`) and QDOASJulia were run on all 144 spectra of the project
(`validation/compare_with_qdoas.jl`): 288 window fits and 3,888 fitted parameters agree to a
median of **3.5 × 10⁻¹¹** of their errors (at most 3.3 × 10⁻⁷), with identical iteration
counts and RMS values equal to 2.6 × 10⁻¹² relative. QDOAS took 7.4 s for the 144 spectra
(1.15 s for one); QDOASJulia 0.41 s on one core and 0.18 s on four.
