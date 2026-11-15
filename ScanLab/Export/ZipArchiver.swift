import Foundation

enum ZipError: Error, LocalizedError {
    case noArchiveProduced

    var errorDescription: String? {
        switch self {
        case .noArchiveProduced:
            return "O sistema não gerou o arquivo ZIP."
        }
    }
}

/// Compacta uma pasta em ZIP sem biblioteca de terceiros.
///
/// O `NSFileCoordinator`, quando lê uma PASTA com a opção `.forUploading`, entrega um
/// arquivo ZIP temporário dela (é o mecanismo que o sistema usa para enviar pastas).
/// O ZIP só existe durante o bloco, então copiamos para o destino lá dentro.
enum ZipArchiver {
    /// Gera `scan-<id>.zip` na pasta temporária com tudo o que está em `outputs/`.
    /// Dentro do ZIP os arquivos ficam numa pasta `scan-<id>/`, com os nomes originais.
    /// Síncrono: chamar fora da thread principal.
    static func zipOutputs(scanID: String) throws -> URL {
        let fileManager = FileManager.default
        let outputs = ScanStore.shared.outputsDirectory(for: scanID)
        let base = fileManager.temporaryDirectory.appendingPathComponent("ScanLabShare", isDirectory: true)
        // Cópia com o nome do scan: é o nome da pasta de origem que aparece dentro do ZIP.
        let staging = base.appendingPathComponent("scan-\(scanID)", isDirectory: true)
        let zipURL = base.appendingPathComponent("scan-\(scanID).zip")

        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: staging.path) {
            try fileManager.removeItem(at: staging)
        }
        try fileManager.copyItem(at: outputs, to: staging)
        defer {
            try? fileManager.removeItem(at: staging)
        }

        try zipFolder(staging, to: zipURL)
        AppLog.info(.export, "ZIP do scan \(scanID): \(AppPaths.formatBytes(AppPaths.fileSize(zipURL)))")
        return zipURL
    }

    /// Síncrono: chamar fora da thread principal.
    static func zipFolder(_ folder: URL, to destination: URL) throws {
        var coordinatorError: NSError?
        var copyError: Error?
        var produced = false

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: folder, options: [.forUploading], error: &coordinatorError) { zippedURL in
            do {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: zippedURL, to: destination)
                produced = true
            } catch {
                copyError = error
            }
        }

        if let error = coordinatorError {
            throw error
        }
        if let error = copyError {
            throw error
        }
        if !produced {
            throw ZipError.noArchiveProduced
        }
    }
}
