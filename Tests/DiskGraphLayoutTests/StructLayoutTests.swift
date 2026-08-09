import Testing
import simd
@testable import DiskGraphLayout

/// The instance and uniform structs are read by hand-written Metal declarations, so a
/// silent change in Swift's layout would corrupt every vertex rather than fail to build.
/// These pin the numbers that `Graph.metal` assumes.
@Suite struct CellInstanceLayoutTests {
    @Test func instanceStrideMatchesTheShaderDeclaration() {
        // 52 bytes of fields, rounded up to the 16-byte alignment SIMD4<Float> imposes.
        #expect(MemoryLayout<CellInstance>.size == 52)
        #expect(MemoryLayout<CellInstance>.stride == 64)
        #expect(MemoryLayout<CellInstance>.alignment == 16)
    }

    @Test func fieldOffsetsMatchTheShaderDeclaration() {
        #expect(MemoryLayout<CellInstance>.offset(of: \.pie) == 0)
        #expect(MemoryLayout<CellInstance>.offset(of: \.rect) == 16)
        #expect(MemoryLayout<CellInstance>.offset(of: \.color) == 32)
        #expect(MemoryLayout<CellInstance>.offset(of: \.pieAlpha) == 36)
        #expect(MemoryLayout<CellInstance>.offset(of: \.rectAlpha) == 40)
        #expect(MemoryLayout<CellInstance>.offset(of: \.nodeID) == 44)
        #expect(MemoryLayout<CellInstance>.offset(of: \.flags) == 48)
    }

    @Test func flagBitsMatchTheShaderConstants() {
        #expect(CellFlags.directory.rawValue == 1 << 0)
        #expect(CellFlags.merged.rawValue == 1 << 1)
        #expect(CellFlags.searchMiss.rawValue == 1 << 2)
        #expect(CellFlags.package.rawValue == 1 << 3)
        #expect(CellFlags.inTreeMap.rawValue == 1 << 4)
    }

    /// The renderer packs colours straight into the buffer, so byte order matters.
    @Test func colourPackingIsLittleEndianRGBA() {
        let red = CellPalette.packed(r: 1, g: 0, b: 0, a: 1)
        #expect(red == 0xFF00_00FF)
        let green = CellPalette.packed(r: 0, g: 1, b: 0, a: 1)
        #expect(green == 0xFF00_FF00)
        let blue = CellPalette.packed(r: 0, g: 0, b: 1, a: 1)
        #expect(blue == 0xFFFF_0000)
    }
}
