//
//  ProcessDiagnostics.swift
//  Ghost Mode
//

import Darwin
import Foundation

// MARK: - Process Diagnostics (Mach Kernel, < 1 Microsecond, 0 Subprocesses)

public struct ProcessDiagnostics {
    public static func getMemoryFootprintMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            return Double(info.resident_size) / (1024.0 * 1024.0)
        }
        return 16.0
    }

    public static func getGhostModeCPUPercentage() -> Double {
        var threadList: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        let kerr = task_threads(mach_task_self_, &threadList, &threadCount)
        guard kerr == KERN_SUCCESS, let list = threadList else { return 0.0 }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: list),
                vm_size_t(threadCount * UInt32(MemoryLayout<thread_t>.size))
            )
        }

        var totalUsage: Double = 0.0
        for i in 0..<Int(threadCount) {
            let thread = list[i]
            defer { mach_port_deallocate(mach_task_self_, thread) }

            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<natural_t>.size)
            let thErr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            if thErr == KERN_SUCCESS && (info.flags & TH_FLAGS_IDLE) == 0 {
                totalUsage += (Double(info.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
            }
        }
        return totalUsage
    }
}
