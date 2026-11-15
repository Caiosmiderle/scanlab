import Foundation

/// Versão do app lida do Info.plist (MARKETING_VERSION e CURRENT_PROJECT_VERSION do project.yml).
enum AppInfo {
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        return "\(version) (\(build))"
    }
}

/// Dados do aparelho usados na tela inicial e, mais adiante, no meta.json e nos logs.
/// Só Foundation de propósito: UIDevice é isolado na thread principal e isso
/// complicaria chamar daqui a partir de filas de background.
enum DeviceInfo {
    /// Identificador de hardware, por exemplo "iPad14,5". Vem de uname().
    static var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        // `machine` é uma tupla de CChar de tamanho fixo; percorremos até o terminador nulo.
        let mirror = Mirror(reflecting: systemInfo.machine)
        var identifier = ""
        for child in mirror.children {
            guard let value = child.value as? Int8, value != 0 else { break }
            identifier.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "desconhecido" : identifier
    }

    /// Texto do sistema, por exemplo "Version 27.0 (Build 25A123)".
    static var systemVersion: String {
        return ProcessInfo.processInfo.operatingSystemVersionString
    }
}
