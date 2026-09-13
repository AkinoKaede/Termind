import Testing

@testable import TermindIOS

struct DeviceCensorshipTests {
    @Test
    func colorDetectionHandlesColorGrayscaleAndMissingPixels() {
        #expect(DeviceCensorship.containsColoredPixel([0, 0, 255, 255]))
        #expect(!DeviceCensorship.containsColoredPixel([64, 64, 64, 255]))
        #expect(!DeviceCensorship.containsColoredPixel([]))
    }
}
