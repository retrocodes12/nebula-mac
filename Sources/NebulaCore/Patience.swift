import Foundation

/// Waiting on work that must not be cut short, without being held up by it.
///
/// An add-on asleep on a free host can take twenty seconds to answer its manifest. The page
/// that asked should not stand still that long, but the answer is still worth having — for the
/// next page, and for the one after. So the work runs on as its own task, and a caller waits for
/// it only as long as it can afford.
public enum Patience {
    /// The task's value if it has one within `seconds`, else nil. Cancelling the caller stops
    /// the wait at once. The task itself is never cancelled from here: it runs on and finishes.
    public static func value<T: Sendable>(of task: Task<T, Never>, within seconds: Double) async -> T? {
        let once = Once<T?>()
        let timer: Task<Void, Never>? = seconds.isFinite ? Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 86_400)) * 1_000_000_000))
            once.fire(nil)
        } : nil
        Task { once.fire(await task.value) }
        let v = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in once.arm(c) }
        } onCancel: {
            once.fire(nil)
        }
        timer?.cancel()
        return v
    }

    /// How long an add-on that did not answer is passed by before it is asked again: two
    /// minutes after one miss, doubling with each miss in a row, never more than sixteen.
    public static func missWindow(_ misses: Int, first: TimeInterval = 120, atMost: TimeInterval = 960) -> TimeInterval {
        min(atMost, first * pow(2, Double(max(0, min(misses, 10) - 1))))
    }
}

/// A continuation that is resumed once, by whichever of several parties gets there first — and
/// that may be fired before anyone waits on it.
final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    private var result: T?
    private var fired = false

    func arm(_ c: CheckedContinuation<T, Never>) {
        lock.lock()
        if fired, let r = result {
            lock.unlock()
            c.resume(returning: r)
            return
        }
        cont = c
        lock.unlock()
    }

    func fire(_ value: T) {
        lock.lock()
        guard !fired else { lock.unlock(); return }
        fired = true
        if let c = cont {
            cont = nil
            lock.unlock()
            c.resume(returning: value)
        } else {
            result = value
            lock.unlock()
        }
    }
}
