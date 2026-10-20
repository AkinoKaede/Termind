// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public nonisolated enum NvidiaMetricsError: Error { case invalidOutput }

/// NVIDIA XML is remote data. Only scalar fields under the current physical GPU are collected.
public nonisolated final class NvidiaMetricsParser: NSObject, XMLParserDelegate {
    public static let maximumBytes = 1_048_576
    private var path: [String] = []
    private var text = ""
    private var fields: [String: String] = [:]
    private var devices: [NvidiaGPU] = []
    private var cuda: String?
    private var validRoot = false

    public static func parse(_ data: Data) throws -> NvidiaSnapshot {
        guard data.count <= maximumBytes,
            let source = String(data: data, encoding: .utf8),
            !source.localizedCaseInsensitiveContains("<!ENTITY")
        else { throw NvidiaMetricsError.invalidOutput }
        let delegate = NvidiaMetricsParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), delegate.validRoot,
            Set(delegate.devices.map(\.id)).count == delegate.devices.count
        else { throw NvidiaMetricsError.invalidOutput }
        return NvidiaSnapshot(cudaVersion: delegate.cuda, devices: delegate.devices)
    }

    public func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        path.append(elementName)
        if path == ["nvidia_smi_log"] { validRoot = true }
        if path == ["nvidia_smi_log", "gpu"] { fields = [:] }
        text = ""
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    public func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == ["nvidia_smi_log", "cuda_version"] { cuda = available(value) }
        if path.count >= 3, path.prefix(2) == ["nvidia_smi_log", "gpu"] {
            fields[path.dropFirst(2).joined(separator: "/")] = value
        }
        if path == ["nvidia_smi_log", "gpu"] {
            guard let id = available(fields["uuid"]), let name = available(fields["product_name"]) else {
                parser.abortParsing()
                return
            }
            devices.append(
                NvidiaGPU(
                    id: id, name: name,
                    utilization: percent("utilization/gpu_util"),
                    memoryUsed: bytes("fb_memory_usage/used"), memoryTotal: bytes("fb_memory_usage/total"),
                    memoryFree: bytes("fb_memory_usage/free"), memoryUtilization: percent("utilization/memory_util"),
                    encoder: percent("utilization/encoder_util"), decoder: percent("utilization/decoder_util"),
                    fan: percent("fan_speed"), vbios: available(fields["vbios_version"])
                ))
        }
        path.removeLast()
        text = ""
    }

    private func available(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "N/A", value != "[N/A]" else { return nil }
        return value
    }

    private func percent(_ key: String) -> Double? {
        guard let raw = fields[key], let token = raw.split(separator: " ").first,
            let value = Double(token), value.isFinite, (0...100).contains(value)
        else { return nil }
        return value
    }

    private func bytes(_ key: String) -> Double? {
        guard let raw = fields[key] else { return nil }
        let parts = raw.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]), value.isFinite, value >= 0 else { return nil }
        let factor: Double
        switch parts[1] {
        case "KiB": factor = 1024
        case "MiB": factor = 1024 * 1024
        case "GiB": factor = 1024 * 1024 * 1024
        case "B": factor = 1
        default: return nil
        }
        let result = value * factor
        return result.isFinite ? result : nil
    }
}
