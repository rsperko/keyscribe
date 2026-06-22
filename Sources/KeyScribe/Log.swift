import os

enum Log {
    static let bias = Logger(subsystem: "com.keyscribe.app", category: "bias")
    static let context = Logger(subsystem: "com.keyscribe.app", category: "context")
    static let models = Logger(subsystem: "com.keyscribe.app", category: "models")
    static let insertion = Logger(subsystem: "com.keyscribe.app", category: "insertion")
}
