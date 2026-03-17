import Foundation
import Testing
@testable import bitchat

struct WalletReloadSchedulerTests {
    @Test("coalesces burst schedules into one execution")
    @MainActor
    func coalescesBurstSchedules() async {
        let scheduler = WalletReloadScheduler(delayMilliseconds: 20)
        var executions = 0

        scheduler.schedule { executions += 1 }
        scheduler.schedule { executions += 1 }
        scheduler.schedule { executions += 1 }

        // Under parallel test load, the MainActor can be temporarily busy.
        // Poll for a short window instead of asserting on a single fixed sleep.
        let deadline = Date().addingTimeInterval(2.0)
        while executions < 1 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        #expect(executions == 1)

        scheduler.cancel()
    }

    @Test("cancel prevents pending execution")
    @MainActor
    func cancelPreventsExecution() async {
        let scheduler = WalletReloadScheduler(delayMilliseconds: 30)
        var executions = 0

        scheduler.schedule { executions += 1 }
        scheduler.cancel()

        try? await Task.sleep(nanoseconds: 70_000_000)
        #expect(executions == 0)
    }

    @Test("immediate schedule executes without debounce delay")
    @MainActor
    func immediateExecutes() async {
        let scheduler = WalletReloadScheduler(delayMilliseconds: 200)
        var executions = 0

        scheduler.schedule(immediate: true) { executions += 1 }
        await Task.yield()

        #expect(executions == 1)
        scheduler.cancel()
    }
}
