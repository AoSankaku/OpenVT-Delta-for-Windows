<p align="center">
  <img src="branding/delta-icon.svg" width="180" />
</p>
<h1 align="center">OpenVT Delta for Windows</h1>

An independent Windows fork of [OpenVT](https://github.com/erodozer/open-vt) by erodozer.
The original MIT copyright and third-party licenses are retained. This fork includes
AI-assisted changes and is maintained separately from the upstream project.

**Windows preview:** download the complete ZIP from
[GitHub Releases](https://github.com/AoSankaku/OpenVT-Delta-for-Windows/releases).
Extract it, then run the `OpenVTDelta-<branch>-<commit>.exe` listed in `release.json`.
This is a portable application; keep the whole extracted folder together.

**日本語:** [リリースページ](https://github.com/AoSankaku/OpenVT-Delta-for-Windows/releases)から
ZIPをダウンロードし、すべて展開してから `release.json` に記載されたEXEを起動してください。
モデルと個人設定は同梱していません。利用許可のあるモデルを読み込んでください。
初回のプレビュー版として公開しており、Windows 11 x64を対象にしています。

### Supported Trackers

- OpenSeeFace (bundled with Windows releases; separate executable on Linux)
- VTubeStudio (TCP over Wi-fi)

### Differences from Alternatives

- based on OpenVT's cross-platform codebase
- Windows 11 support (x64)
- open source development allowing for community driven feature delivery 
- transparent window support to simplify alpha based capture in OBS
- adjustable filtering settings, allowing for sharper scaling of pixel art models
- multi-window popout controls

### VTube Studio Compatibility

OpenVT Delta for Windows strives to be largely compatible with [VTubeStudio](https://denchisoft.com/).
Assets can be used between the two, sharing the same files without need to make adjustments.  Any OpenVT Delta for Windows specific settings are kept separately to avoid possible collisions with namespacing.  Where possible, VTubeStudio will still be respected as the standard.

Feature parity with VTS is a goal, excluding more complex features such as plugin compatibility, and VNet.

## How is it Built?

The majority of the vtuber ecosystem is built in Unity, largely due to familiarity of the software for 3D applications and the direct support for Live2D being provided by Cubism. By contrast, OpenVT Delta for Windows is built in Godot with entirely open source solutions.

OpenVT Delta for Windows uses Ayagami for Live2D rendering and retains the upstream dependencies' original licenses and credits.

### Building Dependencies

This should be done before attempting to open or run the project, otherwise Godot will complain about missing files and classes.

Please follow the readmes and build instructions of any git submodules included in the [thirdparty/](./thirdparty) directory to know of any specifics, some may require additional dependencies to be installed.  Git submodules are subject to changes as critical improvements in dependencies are made.

The provided [build_dependencies.sh](./build_dependencies.sh) script is designed to build each submodule and move its outputs to the required locations in the project filesystem for OpenVT Delta for Windows to run.

### Windows 11 (x64)

Windows releases contain a matching `OpenVTDelta-<branch>-<commit>.exe` and `.pck`, `release.json`, the native extension DLLs,
and an `openseeface` folder.
Extract the entire release folder before running the EXE listed in `release.json`; keep all of these
files together. No Godot editor or Rust installation is needed to run a release.

OpenSeeFace 1.20.5 is included and starts automatically with OpenVT Delta for Windows when
**OpenSeeFace (Webcam)** is the selected face tracker. No separate installation
or Python setup is needed. Webcam frames are processed locally; facial tracking
parameters are sent to OpenVT Delta for Windows over loopback UDP (port 11573 by default).
OpenVT Delta for Windows stops the process it started when you disconnect, change trackers, or quit.

Use **カメラ ONにする / カメラ OFFにする** at the top right of the main screen
to start or stop webcam tracking. The status below the button shows whether it is
waiting for data, tracking a face, or needs a retry. This control stays in the
model window when the settings panels are popped out.

Live2D models without tracking bindings receive standard head, eye, and mouth
connections automatically. Saved custom graphs and VTube Studio parameter
mappings keep their configured behavior.

In **Settings → Tracking → Face Tracking**, choose the camera index (0 by default),
capture FPS, and UDP port. **Start automatically** controls startup, and
**Use bundled OpenSeeFace** can be disabled to receive data from an external
tracker. These settings are saved with the profile. An external tracker already
sending data is reused without starting another copy. If the camera is unavailable,
the status message helps you reconnect after correcting the camera settings.

VTubeStudio tracking, Live2D/VRM models, microphone
input, global keyboard/mouse tracking, and popout panels are available on Windows.
Virtual webcam output through v4l2-loopback is Linux-only; on Windows, capture the
OpenVT Delta for Windows window with OBS. Global pen pressure tracking is currently unavailable on
Windows.

To build locally, install Git, Rust with the `x86_64-pc-windows-msvc` toolchain,
Visual Studio Build Tools with **Desktop development with C++** and a Windows SDK,
and Python with SCons 4.10.1. Run these commands from PowerShell in this repository:

```powershell
git submodule update --init --recursive
python -m pip install scons==4.10.1
./build_godot_windows.ps1
./build_windows.ps1
```

The first command prepares the pinned dependencies. The engine build compiles both
a Godot 4.7.1 editor and a release template with Ayagami's required blending patch;
the standard Godot download cannot render these Live2D shaders correctly. The
first build takes time, and subsequent engine builds reuse the compiled objects.
`build_windows.ps1` builds the Windows DLLs, downloads the pinned OpenSeeFace
release and corresponding LGPL library source, verifies their SHA-256 hashes,
imports the project, and exports a complete release to `bin/windows/`.
Downloads are cached in `bin/downloads/`. For source development, prepare the
webcam tracker with `./prepare_openseeface.ps1`.
To prepare only the addons for development,
run `./build_dependencies.ps1`. Custom patched engines can be selected with
`./build_windows.ps1 -Godot <editor.exe> -Template <release-template.exe>`.

The GitHub **Build Windows distribution** workflow can be run manually. It builds
and checks the Windows release and saves the ZIP as the `openvt-delta.windows` artifact.
It does not publish to itch.io or any other service automatically.

## References

- https://github.com/DenchiSoft/VTubeStudio
- https://github.com/emilianavt/OpenSeeFace

## Licensing

Additional licenses are found in the [/license](./license) directory.

The Windows OpenSeeFace bundle retains its BSD 2-Clause license, upstream and
frozen-runtime dependency notices, and the complete corresponding source for the
LGPL 2.1 DShowCapture DLLs. The DLLs remain separate and replaceable.
MPL 2.0 Eigen source used by ONNX Runtime is included as well. Keep the
entire `openseeface` folder when redistributing a Windows release; see
[OpenSeeFace-NOTICE.txt](./license/OpenSeeFace-NOTICE.txt) for attribution and
source locations. Dependency versions and notice provenance are recorded in
[thirdparty/openseeface.json](./thirdparty/openseeface.json) and
[thirdparty/openseeface-notices.json](./thirdparty/openseeface-notices.json).

See [DISTRIBUTION.md](./DISTRIBUTION.md) for complete redistribution instructions.
Godot engine notices, native Rust dependency licenses and corresponding sources,
and MToon's original license are included with the Windows package.

Create the distributable ZIP with `./package_windows.ps1` after building.
Use `./package_windows.ps1 -DeployToProject` to install the same verified payload
into this checkout. User profiles and local test models are excluded.

## Optional model verification

Model-free checks are in `tests/windows_smoke.gd`, `tests/popout_panel_test.gd`,
`tests/openseeface_test.gd`, and `tests/live2d_metadata_test.gd`.
The tracking and model-shutdown integration checks require a Live2D model with
standard head, eye, and mouth parameters. Set `OPENVT_TEST_MODEL` to its
`.model3.json` path before running `tests/live2d_tracking_test.gd` or
`tests/shutdown_model_test.gd`. These checks create ignored workspace copies for
sidecar changes; no model is included in this repository. Use an isolated
`APPDATA`/`LOCALAPPDATA` for tests so normal application settings stay separate.
