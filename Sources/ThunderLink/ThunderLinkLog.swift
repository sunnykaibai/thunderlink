import OSLog

enum ThunderLinkLog {
    static let network = Logger(subsystem: "com.sunny.thunderlink", category: "network")
    static let input = Logger(subsystem: "com.sunny.thunderlink", category: "input")
}
