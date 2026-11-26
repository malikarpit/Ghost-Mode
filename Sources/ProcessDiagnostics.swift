//
//  ProcessDiagnostics.swift
//  Ghost Mode
//

import Darwin
import Foundation

// MARK: - Process Diagnostics (Mach Kernel, < 1 Microsecond, 0 Subprocesses)

public struct ProcessDiagnostics {
    private static let samplerLock = NSLock()
    private static var lastSampleWallSec: Double?
    private static var lastSampleCPUSec: Double?
    private static var lastComputedCPUPercent: Double = 0.0

    /// Returns the process's private physical memory footprint in MB (matching Activity Monitor Memory).
    public static func getMemoryFootprintMB() -> Double {
        var vmInfo = task_vm_info_data_t()
        var vmCount = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let vmErr = withUnsafeMutablePointer(to: &vmInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &vmCount)
            }
        }
        if vmErr == KERN_SUCCESS, vmInfo.phys_footprint > 0 {
            return Double(vmInfo.phys_footprint) / (1024.0 * 1024.0)
        }

        var basicInfo = mach_task_basic_info()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<natural_t>.stride
        )
        let kerr = withUnsafeMutablePointer(to: &basicInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
            }
        }
        if kerr == KERN_SUCCESS {
            return Double(basicInfo.resident_size) / (1024.0 * 1024.0)
        }
        return 16.0
    }

    /// Computes average process CPU percentage across a sampling interval.
    public static func computeCPUPercentage(
        previousCPUSeconds: Double?,
        currentCPUSeconds: Double,
        previousWallSeconds: Double?,
        currentWallSeconds: Double
    ) -> Double {
        guard let prevCPU = previousCPUSeconds, let prevWall = previousWallSeconds else {
            return 0.0
        }
        let wallDelta = currentWallSeconds - prevWall
        guard wallDelta >= 0.05 else {
            return 0.0
        }
        let cpuDelta = max(0.0, currentCPUSeconds - prevCPU)
        return (cpuDelta / wallDelta) * 100.0
    }

    private static func readProcessUsageAndWallTime() -> (cpuSeconds: Double, wallSeconds: Double)? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return nil
        }
        let cpuSeconds = Double(usage.ru_utime.tv_sec)
            + Double(usage.ru_utime.tv_usec) / 1_000_000.0
            + Double(usage.ru_stime.tv_sec)
            + Double(usage.ru_stime.tv_usec) / 1_000_000.0
        let wallSeconds = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000.0
        return (cpuSeconds, wallSeconds)
    }

    /// Seeds the CPU sampling baseline when uninitialized or stale so the next sample has a meaningful window.
    /// Returns `true` if a fresh baseline was recorded.
    @discardableResult
    public static func warmUpCPUBaselineIfStale(maxAgeSeconds: Double = 8.0) -> Bool {
        guard let reading = readProcessUsageAndWallTime() else { return false }
        samplerLock.lock()
        defer { samplerLock.unlock() }

        let isStale = lastSampleWallSec.map { (reading.wallSeconds - $0) >= maxAgeSeconds } ?? true
        if isStale {
            lastSampleCPUSec = reading.cpuSeconds
            lastSampleWallSec = reading.wallSeconds
            return true
        }
        return false
    }

    /// Samples process CPU percentage cleanly, returning `needsFollowup = true` only when a fresh baseline
    /// was just seeded and needs a brief follow-up measurement (`~0.5s`) instead of waiting 5 seconds.
    public static func sampleProcessCPU() -> (percent: Double, needsFollowup: Bool) {
        guard let reading = readProcessUsageAndWallTime() else {
            return (0.0, false)
        }

        samplerLock.lock()
        defer { samplerLock.unlock() }

        guard let prevCPU = lastSampleCPUSec, let prevWall = lastSampleWallSec else {
            lastSampleCPUSec = reading.cpuSeconds
            lastSampleWallSec = reading.wallSeconds
            lastComputedCPUPercent = 0.0
            return (0.0, true)
        }

        let wallDelta = reading.wallSeconds - prevWall
        if wallDelta > 15.0 {
            lastSampleCPUSec = reading.cpuSeconds
            lastSampleWallSec = reading.wallSeconds
            return (lastComputedCPUPercent, true)
        }

        guard wallDelta >= 0.05 else {
            return (lastComputedCPUPercent, true)
        }

        let pct = computeCPUPercentage(
            previousCPUSeconds: prevCPU,
            currentCPUSeconds: reading.cpuSeconds,
            previousWallSeconds: prevWall,
            currentWallSeconds: reading.wallSeconds
        )
        lastSampleCPUSec = reading.cpuSeconds
        lastSampleWallSec = reading.wallSeconds
        lastComputedCPUPercent = pct
        return (pct, false)
    }

    public static func getGhostModeCPUPercentage() -> Double {
        sampleProcessCPU().percent
    }
}
