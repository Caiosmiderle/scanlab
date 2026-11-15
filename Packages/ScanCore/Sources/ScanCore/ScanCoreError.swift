import Foundation

/// Erros do ScanCore, com mensagem em português para aparecer direto na interface.
public enum ScanCoreError: Error, Equatable, LocalizedError {
    case cannotCreateFile(String)
    case invalidMagic
    case truncatedFile
    case inconsistentMesh(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateFile(let name):
            return "Não foi possível criar o arquivo \(name)."
        case .invalidMagic:
            return "O arquivo não é um mesh.bin do ScanLab (cabeçalho desconhecido)."
        case .truncatedFile:
            return "O arquivo está incompleto ou corrompido."
        case .inconsistentMesh(let detail):
            return "Malha inconsistente: \(detail)"
        }
    }
}
