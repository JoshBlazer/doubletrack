# Planted-behavior evaluation corpus

Not built yet (lands with M3). This directory will hold small dual-booted SQLite apps,
each with **known, planted** behavior changes between the two Rails versions (and at
least one app with **no** behavior change). `make eval` will replay them and report
precision/recall against the planted ground truth. CI fails if either regresses.
