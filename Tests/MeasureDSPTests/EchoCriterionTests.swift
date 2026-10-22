import Foundation
import XCTest
@testable import MeasureDSP

final class EchoCriterionTests: XCTestCase {
    let fs = 48_000.0

    func testDirectSoundAloneHasNoEcho() {
        var ir = [Double](repeating: 0, count: 48_000)
        ir[100] = 1
        let r = EchoCriterion.analyze(ir, sampleRate: fs, onset: 100, programme: .speech)
        XCTAssertEqual(r.maxEK, 0, accuracy: 1e-12)
        XCTAssertEqual(r.audibleShare, 0)
    }

    func testStrongLateReflectionIsAnEcho() {
        var ir = [Double](repeating: 0, count: 48_000)
        ir[100] = 1
        ir[100 + 4800] = 1 // equal level, 100 ms later
        let r = EchoCriterion.analyze(ir, sampleRate: fs, onset: 100, programme: .speech)
        // t_S jumps from 0 to 0.1 * 1 / 2 = 0.05 s at 100 ms; over Δτ_E = 9 ms that is EK = 5.6.
        XCTAssertEqual(r.maxEK, 0.05 / 0.009, accuracy: 1e-6)
        XCTAssertEqual(r.timeOfMax, 0.1, accuracy: 0.0005)
        XCTAssertEqual(r.audibleShare, 50)
    }

    func testWeakReflectionIsNotAnEcho() {
        var ir = [Double](repeating: 0, count: 48_000)
        ir[0] = 1
        ir[4800] = 0.01
        let r = EchoCriterion.analyze(ir, sampleRate: fs, onset: 0, programme: .speech)
        let w = pow(0.01, 2.0 / 3.0)
        XCTAssertEqual(r.maxEK, 0.1 * w / (1 + w) / 0.009, accuracy: 1e-6)
        XCTAssertEqual(r.audibleShare, 0)

        // Music uses n = 1 and Δτ_E = 14 ms.
        let m = EchoCriterion.analyze(ir, sampleRate: fs, onset: 0, programme: .music)
        XCTAssertEqual(m.maxEK, 0.1 * 0.01 / 1.01 / 0.014, accuracy: 1e-6)
    }
}
