// Temporary boot marker — removed in Task 12.
window.__vizScriptLoaded = true;

// ponytail: stub — Tasks 6-11 flesh this out.
window.MilkViz = {};

// Temporary probe: confirms the script executed in the page's JS context.
// Removed in Task 12 along with __vizScriptLoaded.
setTimeout(function() {
    console.log('VIZ boot', !!window.MilkViz, window.__vizScriptLoaded === true);
}, 3000);
