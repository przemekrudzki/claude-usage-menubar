// Test runner entry point. Each task adds a `func <name>Checks()` in its own
// Checks_*.swift file and wires a call in here. `t.finish()` must be last.

scaffoldChecks()
dateParseChecks()
formatChecks()
paletteChecks()
usageParserChecks()
keychainReaderChecks()

t.finish()
