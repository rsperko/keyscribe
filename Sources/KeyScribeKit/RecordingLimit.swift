public enum RecordingLimit {
    // A backstop for a forgotten or stuck take, not a length every engine handles well: a model whose
    // accuracy collapses sooner carries its own lower limit in the catalog.
    public static let backstopSeconds = 900.0

    public static func modelLimit(engineId: String) -> Double? {
        SpeechModelCatalog.entry(for: engineId)?.maxRecordingSeconds
    }

    public static func seconds(backstop: Double, modelLimit: Double?) -> Double {
        min(backstop, modelLimit ?? backstop)
    }

    public static func phrase(seconds: Double) -> String {
        let whole = max(1, Int(seconds.rounded(.up)))
        return whole % 60 == 0 ? "\(whole / 60)-minute" : "\(whole)-second"
    }
}
