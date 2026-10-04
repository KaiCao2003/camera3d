# BrainBuilder

Native macOS workspace for splitting fluorescence montages into serial mouse
brain sections, registering them to Allen CCFv3, reviewing probe-track
candidates, and exporting auditable atlas coordinates.

## Run

```sh
./script/build_and_run.sh
```

The release app is written to `dist/BrainBuilder.app`. macOS 14+ on Apple
Silicon is currently supported. The first atlas/pose run may download the
BrainGlobe atlas and DeepSlice weights; later runs reuse Application Support
caches.

## Registration workflow

1. Keep the source selector on **Sections**. **Tile preview** is intentionally
   excluded from quantitative registration.
2. Open **Atlas** and confirm exactly one structural channel and, optionally,
   one probe-track channel.
3. Run **Auto Align (Affine)**. This materializes independent section crops,
   estimates planes with DeepSlice, and performs SimpleITK affine registration.
4. Review **Overlay**, **Track**, **Borders**, **Checker**, and **Diff**. Accept
   each satisfactory section; review probe-track candidates separately.
5. Build the blind 3D partition, explicitly review split/merge/reassignment and
   unassigned points, then lock it. Export only after all section and manual
   disposition blockers are cleared.

Review state is saved under `exports/registration-worker/saved-projects` and is
restored only when the dataset fingerprint still matches. Worker runs use new
transaction folders, so a canceled retry does not overwrite the last valid
registration.

The Atlas workspace opens directly on the review canvas. **Histology** and
**Atlas** show each input separately; **Overlay** blends them with adjustable
opacity. Zoom, drag to pan, and **Fit** preserve the image coordinates used for
brain-region lookup. The queue and inspector can be hidden, and a completed
run's detailed report opens separately from the canvas.

Use **Correct…** to change the AP plane or its two tilt angles. Apply the plane
before selecting matching landmarks on the new atlas reference and the
canonical structural image. At least three non-collinear pairs are required;
more well-spaced anatomical landmarks allow an informative fit residual. Each
correction writes a new run, clears acceptance and dependent track review, and
can be undone with **More → Undo correction**. Landmark RMS is an in-sample
fit residual. Tissue-mask IoU measures the outside shape, not internal region
accuracy; neither is an independent anatomical validation.

Registration inputs retain the original aligned structural/probe crop pixels.
A separate `selectionMaskPath` records the selected section's geometric domain;
it is rotated with the raster exactly once. The 3D display alpha is never used
to erase registration intensities. Tissue masks are derived separately within
that domain. Legacy prepared images may already have lost signal through the
old display mask and must be prepared again from the source montage to recover it.

## Official ABBA handoff

The built-in automatic pipeline is DeepSlice plus SimpleITK affine, not ABBA.
**Run → Official ABBA · Affine + Spline** uses the configured isolated ABBA
runtime to export, refine all sections, validate the coordinate fields, and
open the result. The run writes a new output folder and supports cancellation.
**More → Export to ABBA…** creates canonical structural TIFFs, optional probe
sidecars, a QuickNII project, and a hash manifest for the official ABBA plugin.
The bundle includes instructions and an isolated `abba-python==0.11.0` runner
for importing and refining those sections with official Elastix affine/spline.
It requires its own Java/Maven/Elastix runtime; exporting a bundle does not mean
that ABBA has run or that the resulting registration has been accepted.

ABBA applies a common median slicing angle on QuickNII import. Its coordinate
origin convention is recorded in the manifest; the runner retains native XYZ
millimeter fields and explicit AP/DV/ML micrometer fields in the source pixel
grid. Nonlinear results are kept as official ABBA artifacts, not silently
represented by a BrainBuilder affine transform.

**More → Open ABBA Result…** validates the result against its original handoff
folder and opens a separate, read-only section viewer with histology, atlas,
opacity overlay, borders, and zoom. These images are sampled through the actual
nonlinear coordinate fields. This does not change affine-project acceptance or
the existing 3D tracks.

On this workstation, the isolated runtime can reproduce a full refinement:

```sh
registration-worker/abba/run-local.command \
  --bundle exports/abba-bridge/unique-input-1400-verified \
  --output /path/to/new-results --stage spline
```

`run-local.command` uses the runtime at `~/.cache/brainbuilder-abba` (override
with `BRAINBUILDER_ABBA_RUNTIME`). Elastix and transformix require the supplied
`bin/` and `lib/` layout. Each result includes the official `.abba` project,
coordinate fields, runtime versions, input hashes, and stage verification.

Atlas schema-2 exports use a closed-world relative-path/hash manifest and retain
source/review images, transforms, annotation IDs, ontology, every finite
undirected A/B support, source membership, fit QC, and blind-stage digests.
Neither those supports nor any legacy trajectory samples are a Neuropixels site
map, entry/tip measurement, navigation transform, or accuracy conclusion.

## Brain3D retrospective histology review

**Load Brain3D Plan…** verifies the exact `.mouseplan` member/checksum set,
locked handoff digest, subject receipt, and Allen atlas metadata, annotation,
and normalized ontology identities. The reviewer must select one immutable
handoff explicitly; camera3d never writes or upgrades the package.

Brain3D plans and ROI definitions are excluded from DeepSlice, affine
registration, 2D candidate detection, and blind 3D reconstruction inputs. In
the hidden-overlay phase, review every 2D candidate, then use **Blind 3D Track
Review** to deterministically split, merge, or reassign source points. A source
point can belong to at most one finite A/B track and may remain unassigned.
Only after blind lock can the app reveal planned physical shanks, Allen/box ROI
traversal, the full observed-to-planned comparison matrix, and manual
dispositions.

`atlas-export.json` schema 2 records the blind-stage digests, finite observed
supports and fit QC, complete review matrix, ROI interval unions, manual
decisions, and the immutable Brain3D receipt. A changed source-dataset
fingerprint clears the Brain3D context and requires the handoff and any audited
subject rebind to be confirmed again. These outputs are retrospective insertion
evidence only, always `usableForNavigation: false`; they are not surgical
accuracy, safety, clearance, or navigation evidence.

## Mouse colony subject lookup

The Atlas inspector can verify the project subject against the read-only
`mouse_line` integration API on `hhw9l84`. BrainBuilder opens an ephemeral SSH
local forward to the service's loopback-only port `3004`; the API is not exposed
directly on the network. Enter the separate integration token on the first
successful public-ID lookup. It is saved only in macOS Keychain under service
`org.brainbuilder.mouse-line`, account `hhw9l84`, and may be left blank on later
lookups.

A legacy-ID response is shown for review but is never used to change the project
subject automatically. Only an exact public-ID match writes a compact
`colonySubjectReceipt`. The token and full colony record are not persisted, and
the receipt is excluded from blind registration/reconstruction digests. This is
identity evidence only and is always marked `usableForNavigation: false`.

## Verify

```sh
swift test
registration-worker/.venv/bin/pytest -q
./script/build_and_run.sh --verify
```

The scientific worker and its locked package stack are documented in
[`registration-worker/README.md`](registration-worker/README.md).
