// ponytail: optional curated allowlist — invalid names are dropped at runtime via
// intersection with butterchurnPresets.getPresets(). Leave empty to use all presets
// (shuffled, capped at 40). Human QA: populate with exact names from the preset
// global to curate; any name not found in getPresets() is silently skipped.
window.__milkPresets = [];
