# OpenVT Delta for Windows

This is an independent Windows fork of [OpenVT](https://github.com/erodozer/open-vt)
by erodozer. The Delta distribution is maintained separately from upstream.
Its changes include Windows support, bundled webcam tracking, tracking defaults,
and fixes to window controls and shutdown. This fork includes AI-assisted changes.

## Running

Extract the complete ZIP, then run the `OpenVTDelta-<branch>-<commit>.exe`
listed in `release.json`. The filename identifies the source branch and commit.
Keep the PCK, DLLs, `openseeface`, `license`, and `CorrespondingSource` folders
together with the executable. The archive contains no avatar model or saved
user profile. Load a model that you have permission to use.

## Licenses and attribution

The application is distributed under the original MIT license in `LICENSE.txt`.
The original copyright notice is retained. The new product name does not replace
the licenses of upstream OpenVT or any third-party component, and does not imply
upstream endorsement.

- Godot Engine: `license/GODOT_LICENSE.txt` and
  `license/GODOT_THIRDPARTY_NOTICES.txt`, generated from the pinned build engine.
- Godot Engine logo by Andrea Calabró (2017), under
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), from the
  [official Godot press kit](https://godotengine.org/press/).
  The monochrome variant is scaled without changing its proportions;
  see `license/GODOT_LOGO_LICENSE.txt` for the original notice.
- Ayagami, the keylogger, Godot VRM, and MToon: their original licenses in `license`.
- SVG interface icons from [Font Awesome Free 6.7.2](https://fontawesome.com)
  by Fonticons, Inc., under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
  Their fill and display dimensions were adjusted; two arrows were mirrored.
  The original notice is in `license/LICENSE.fontawesome.txt`, and the source
  files and changes are listed in the included icon provenance manifest.
  No Font Awesome font files are distributed.
- Native Rust dependencies: license and notice texts in `license/native-runtime`.
  Fixed-version crate sources are in `CorrespondingSource/native-runtime`;
  provenance and hashes are recorded in the native runtime manifest supplied
  with those notices. MPL-covered sources retain the MPL and their original notices.
- OpenSeeFace and its dependencies: `license/OpenSeeFace-NOTICE.txt`,
  `openseeface/LICENSE`, `openseeface/Licenses`, and `openseeface/AdditionalLicenses`.
  DShowCapture (LGPL 2.1) and Eigen (MPL 2.0) corresponding source is included in
  `openseeface/CorrespondingSource`. The DShowCapture DLLs are separate and replaceable.

Redistribute the complete archive with these licenses, notices, and sources.
The application license does not grant rights to avatars, textures, expressions,
motions, or other models loaded by a user; those assets have their own terms.
