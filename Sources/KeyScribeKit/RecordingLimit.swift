public enum RecordingLimit {
    public static func phrase(seconds: Double) -> String {
        let whole = max(1, Int(seconds.rounded(.up)))
        return whole % 60 == 0 ? "\(whole / 60)-minute" : "\(whole)-second"
    }
}
