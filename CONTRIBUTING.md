# Contributing to OpenVT Delta for Windows

This is an independent Windows fork of OpenVT by erodozer. These guidelines apply
to the Delta fork. Consult upstream's own contribution policy before submitting
changes to the original OpenVT project.

## GDScript internal, Rust external

OpenVT Delta for Windows uses Godot's built-in functionality with few dependencies.
GDScript is the primary language for application behavior. Native integrations
use Godot-Rust; general-purpose integrations belong in separate dependencies.
The `thirdparty` directory pins those dependencies, and `addons` holds the built files.

## Engine and verification

The Windows build uses the pinned Godot 4.7.1 editor and export template with
Ayagami's blending patch. Build with the repository's PowerShell scripts and
verify the affected behavior before contributing. Keep tests isolated from real
user profiles and models; use synthetic tracking for tests that do not need a camera.

## AI-assisted contributions

AI-assisted contributions are accepted in this fork. Contributors remain
responsible for correctness, license compliance, and reviewing generated changes.
Preserve upstream copyright notices, dependency licenses, and required sources.
Do not imply that the original OpenVT project endorses this fork or its changes.
