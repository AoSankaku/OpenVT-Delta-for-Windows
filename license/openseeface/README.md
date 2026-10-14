# Additional OpenSeeFace runtime notices

These files supplement the original `LICENSE` and `Licenses` directory retained
with the unmodified OpenSeeFace v1.20.5 Windows release. Each original license or
copyright notice is retained unchanged. `provenance.json` records its source,
matching version evidence, archive entry, and SHA-256 checksum.

This software is based in part on the work of the Independent JPEG Group.

This product includes software developed by the OpenSSL Project for use in the
OpenSSL Toolkit (https://www.openssl.org/).

This product includes cryptographic software written by Eric Young
(eay@cryptsoft.com). This product includes software written by Tim Hudson
(tjh@cryptsoft.com).

The NumPy notice includes OpenBLAS/LAPACK and the GNU compiler runtime license
with its GCC Runtime Library Exception. The full ONNX Runtime notice includes
its incorporated third-party components. The OpenCV wheel notice describes
multiple platforms; its references to FFmpeg and Qt do not identify files added
to this bundle. The actual upstream frozen Windows directory contains neither
an FFmpeg DLL nor a Qt library. The additional OpenCV source-tree notices cover
the static dependencies listed in the SHA-256-matched OpenCV binary's embedded
build configuration.

## Covered source availability

Eigen is used by ONNX Runtime under the Mozilla Public License 2.0. Its
corresponding source is supplied in
`../CorrespondingSource/eigen-d10b27fe-source.tar.gz`, including the original
source files and `COPYING.MPL2`. It is the Eigen revision
`d10b27fe37736d2944630ecd7557cefa95cf87c9` pinned by the official ONNX Runtime
v1.5.1 source tree. You may use and modify that covered source under its retained
licenses. You may also obtain it from the
[Eigen repository](https://gitlab.com/libeigen/eigen/-/tree/d10b27fe37736d2944630ecd7557cefa95cf87c9)
or its
[source archive mirror](https://eigen.googlesource.com/mirror/+archive/d10b27fe37736d2944630ecd7557cefa95cf87c9.tar.gz).
The supplied archive's SHA-256 is
`c5f714208b3267076c55f577d25dc04ccbf65b3b1d868f5107eb17670460fb74`.

DShowCapture is a separate LGPL 2.1 library. Its corresponding source archive
and replacement instructions are provided in the bundle's main `NOTICE.txt`
and `CorrespondingSource` directory.

## Microsoft runtime components

Microsoft's release runtime DLLs remain unmodified and retain Microsoft's
copyright. Their use and redistribution are governed by the applicable
Microsoft terms, separately from the BSD license for OpenSeeFace. A distributor
must meet the eligibility and distribution requirements of those terms; the
upstream OpenSeeFace license does not grant additional rights over Microsoft
components. See the official
[runtime redistribution guidance](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files),
[Visual Studio 2019 distributable list](https://learn.microsoft.com/en-us/visualstudio/releases/2019/redistribution),
[Build Tools terms](https://visualstudio.microsoft.com/license-terms/mlt031519/),
and [Visual C++ runtime terms](https://visualstudio.microsoft.com/license-terms/vs2022-cruntime/).

## Frozen executable provenance

The original executable is redistributed unchanged. The embedded PyInstaller
bootloader does not record its exact build version. The retained contemporary
PyInstaller 3.6 and 4.0 notices contain the same Bootloader Exception, which
permits distributing a bootloader combined with another program. The 4.0 notice
also contains the Apache 2.0 terms for its runtime hooks. These reference notice
versions are recorded as such, rather than asserted as the executable's exact
build version.

The embedded ONNX Runtime Python module and native library both identify version
1.5.1. The native library is a different upstream build from the public PyPI
1.5.1 wheel; its notice provenance is therefore based on its verified version,
not a claim that those two library files are byte-identical.
