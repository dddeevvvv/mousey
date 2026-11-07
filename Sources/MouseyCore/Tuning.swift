import Foundation

/// Monotonic nanoseconds that keep counting across sleep. The shell reads the clock and passes it in.
public typealias Tick = UInt64

/// Every timing and threshold in one place.
public enum Tuning {
	public static let edgePushPoints = 10.0
	/// A real trackpad reports 50 to 100 points per event at an edge, so distance alone lets a flick toward a scroll bar cross.
	public static let edgePushMinNanos: Tick = 80_000_000
	public static let edgePushPauseNanos: Tick = 250_000_000
	public static let retryNanos: Tick = 5_000_000
	/// Fast retry applies only while the link is answering, so a dead link is not flooded.
	public static let fastRetryWindowNanos: Tick = 300_000_000
	public static let remoteHeartbeatNanos: Tick = 100_000_000
	public static let localHeartbeatNanos: Tick = 1_000_000_000
	/// Frame spacing while probing, so the latency test gets about 125 acks per second.
	public static let probeNanos: Tick = 8_000_000
	public static let targetSilentReturnNanos: Tick = 1_000_000_000
	public static let targetSilentReleaseNanos: Tick = 1_200_000_000
	public static let onlineWindowNanos: Tick = 2_500_000_000
	public static let clockGapNanos: Tick = 1_000_000_000
	public static let userActivityNanos: Tick = 1_000_000_000
	public static let outboxCapacity = 64
}

/// Ticks from `earlier` to `now`, zero if the clock stepped back.
func elapsed(_ now: Tick, since earlier: Tick) -> Tick { now > earlier ? now - earlier : 0 }
