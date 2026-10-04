import Darwin
import Foundation
import XCTest
@testable import BrainBuilder

final class ABBAWorkerCancellationTests: XCTestCase {
    func testCancellationStopsNativeDescendantsAfterPythonLeaderExits() throws {
        let process = Process()
        let readiness = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", """
        import os, subprocess, time
        if os.getpgrp() != os.getpid():
            os.setsid()
        child = subprocess.Popen(
            ['/bin/sh', '-c', 'trap "" TERM; /bin/sleep 60 & echo $!; wait'],
            stdout=subprocess.PIPE, text=True)
        grandchild = int(child.stdout.readline())
        print(f'{child.pid:010d}{grandchild:010d}', end='', flush=True)
        time.sleep(60)
        """]
        process.standardOutput = readiness
        try process.run()
        let groupID = process.processIdentifier
        defer {
            // This test owns only the process group created by its Python fixture.
            if Darwin.getpgid(groupID) == groupID { Darwin.kill(-groupID, SIGKILL) }
            if process.isRunning { process.terminate() }
        }
        let data = try XCTUnwrap(try readiness.fileHandleForReading.read(upToCount: 20))
        let identifiers = String(decoding: data, as: UTF8.self)
        let descendants = [String(identifiers.prefix(10)), String(identifiers.suffix(10))]
            .compactMap { pid_t($0) }
        XCTAssertEqual(descendants.count, 2)
        XCTAssertEqual(Darwin.getpgid(groupID), groupID)
        for pid in descendants { XCTAssertEqual(Darwin.getpgid(pid), groupID) }

        let stopped = RegistrationWorkerService.terminateProcess(
            process,
            includingProcessGroup: true,
            policy: RegistrationWorkerTerminationPolicy(
                gracefulTimeout: 0.1,
                forcedTimeout: 2,
                pollInterval: 0.005
            )
        )

        XCTAssertTrue(stopped)
        XCTAssertFalse(process.isRunning)
        for pid in descendants {
            XCTAssertEqual(Darwin.kill(pid, 0), -1, "Native child \(pid) survived cancellation")
            XCTAssertEqual(errno, ESRCH)
        }
        XCTAssertEqual(Darwin.kill(-groupID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}
