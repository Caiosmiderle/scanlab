import Foundation

/// Destino de bytes dos escritores de arquivo.
///
/// Os escritores gravam em blocos em vez de montar o arquivo inteiro na memória:
/// um scan grande passa de 100 MB e o iPad não pode ter várias cópias disso em RAM.
/// Nos testes usamos `MemorySink`; no app, `FileSink`.
public protocol ByteSink: AnyObject {
    func write(_ data: Data) throws
}

/// Guarda tudo em memória. Só para testes e arquivos pequenos.
public final class MemorySink: ByteSink {
    public private(set) var data = Data()

    public init() {}

    public func write(_ data: Data) throws {
        self.data.append(data)
    }
}

/// Grava direto num arquivo, substituindo o que existir no caminho.
public final class FileSink: ByteSink {
    private let handle: FileHandle
    private var isClosed = false

    public init(url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        guard fileManager.createFile(atPath: url.path, contents: nil) else {
            throw ScanCoreError.cannotCreateFile(url.lastPathComponent)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    public func write(_ data: Data) throws {
        if data.isEmpty {
            return
        }
        try handle.write(contentsOf: data)
    }

    /// Fecha o arquivo. Chamar explicitamente para receber erro de disco cheio;
    /// o `deinit` fecha em silêncio se isso for esquecido.
    public func close() throws {
        if isClosed {
            return
        }
        isClosed = true
        try handle.close()
    }

    deinit {
        if !isClosed {
            try? handle.close()
        }
    }
}

/// Acumulador de bytes little-endian usado pelos escritores binários.
struct ByteBuffer {
    var data: Data

    init(capacity: Int) {
        data = Data()
        data.reserveCapacity(capacity)
    }

    mutating func appendUInt8(_ value: UInt8) {
        data.append(value)
    }

    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    mutating func appendInt32(_ value: Int32) {
        appendUInt32(UInt32(bitPattern: value))
    }

    mutating func appendFloat(_ value: Float) {
        appendUInt32(value.bitPattern)
    }

    mutating func appendASCII(_ text: String) {
        data.append(contentsOf: Array(text.utf8))
    }

    /// Copia o vetor inteiro de uma vez. Válido porque todos os aparelhos da Apple
    /// (e o runner do CI) são little-endian, que é a ordem dos nossos formatos.
    mutating func appendFloats(_ values: [Float]) {
        values.withUnsafeBufferPointer { pointer in
            data.append(pointer)
        }
    }

    mutating func appendUInt32s(_ values: [UInt32]) {
        values.withUnsafeBufferPointer { pointer in
            data.append(pointer)
        }
    }

    mutating func appendBytes(_ values: [UInt8]) {
        data.append(contentsOf: values)
    }
}

/// Leitor sequencial de bytes little-endian, com checagem de limite em toda leitura
/// para um arquivo corrompido virar erro em vez de travar o app.
struct BinaryReader {
    private let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var remaining: Int {
        return data.count - offset
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        return try readArray(count: count, initial: UInt8(0))
    }

    mutating func readUInt32() throws -> UInt32 {
        let values = try readArray(count: 1, initial: UInt32(0))
        return UInt32(littleEndian: values[0])
    }

    mutating func readFloats(_ count: Int) throws -> [Float] {
        return try readArray(count: count, initial: Float(0))
    }

    mutating func readUInt32s(_ count: Int) throws -> [UInt32] {
        return try readArray(count: count, initial: UInt32(0))
    }

    private mutating func readArray<T>(count: Int, initial: T) throws -> [T] {
        let elementSize = MemoryLayout<T>.stride
        // Confere antes de alocar: uma contagem absurda vinda de arquivo corrompido
        // não pode virar um pedido de gigabytes de memória.
        guard count >= 0, count <= remaining / elementSize else {
            throw ScanCoreError.truncatedFile
        }
        var result = [T](repeating: initial, count: count)
        let byteCount = count * elementSize
        if byteCount > 0 {
            let start = offset
            let source = data
            result.withUnsafeMutableBytes { destination in
                source.withUnsafeBytes { bytes in
                    let slice = UnsafeRawBufferPointer(rebasing: bytes[start..<(start + byteCount)])
                    destination.copyMemory(from: slice)
                }
            }
        }
        offset += byteCount
        return result
    }
}
