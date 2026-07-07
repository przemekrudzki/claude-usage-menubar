import ClaudeUsageCore

func paletteChecks() {
    t.group("Palette")
    t.equal(Palette.ring(percent: 10, severity: "normal"), .green)
    t.equal(Palette.ring(percent: 75, severity: "normal"), .amber)
    t.equal(Palette.ring(percent: 95, severity: "normal"), .red)
    t.equal(Palette.ring(percent: 5, severity: "warning"), .amber)
    t.equal(Palette.ring(percent: 5, severity: "critical"), .red)
    t.equal(Palette.ring(percent: 10, severity: "weird"), .green)
}
