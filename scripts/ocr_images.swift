#!/usr/bin/env swift

import Foundation
import Vision
import ImageIO

guard CommandLine.arguments.count >= 4 else {
    fputs("usage: ocr_images.swift <messages.json> <image-dir> [<image-dir> ...] <output.json>\n", stderr)
    exit(2)
}

let messagesPath = CommandLine.arguments[1]
let imageDirs = Array(CommandLine.arguments[2..<(CommandLine.arguments.count - 1)])
let outputPath = CommandLine.arguments.last!

let data = try Data(contentsOf: URL(fileURLWithPath: messagesPath))
let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
let messages = (json["messages"] as? [[String: Any]]) ?? (json["items"] as? [[String: Any]]) ?? []

func value(_ dictionary: [String: Any], _ keys: [String]) -> String? {
    for key in keys {
        if let result = dictionary[key] as? String, !result.isEmpty { return result }
    }
    return nil
}

func findFile(_ key: String) -> String? {
    for directory in imageDirs {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        if let name = items.first(where: { $0.contains(key) }) {
            return URL(fileURLWithPath: directory).appendingPathComponent(name).path
        }
    }
    return nil
}

func recognize(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot decode image"])
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

var output: [[String: Any]] = []
for (index, message) in messages.enumerated() {
    let type = value(message, ["msg_type", "message_type", "type"]) ?? ""
    guard type == "image" || type.isEmpty else { continue }
    let key = value(message, ["image_key", "resource_key", "file_key"]) ?? ""
    guard !key.isEmpty, let path = findFile(key) else { continue }
    do {
        output.append([
            "message_id": value(message, ["message_id", "id"]) ?? "",
            "image_key": key,
            "position": message["position"] ?? index,
            "sent_at": value(message, ["sent_at", "create_time", "timestamp"]) ?? "",
            "local_path": path,
            "ocr_text": try recognize(path)
        ])
    } catch {
        output.append([
            "message_id": value(message, ["message_id", "id"]) ?? "",
            "image_key": key,
            "position": message["position"] ?? index,
            "sent_at": value(message, ["sent_at", "create_time", "timestamp"]) ?? "",
            "local_path": path,
            "ocr_text": "",
            "ocr_error": error.localizedDescription
        ])
    }
}

let outputData = try JSONSerialization.data(withJSONObject: ["items": output], options: [.prettyPrinted, .sortedKeys])
try outputData.write(to: URL(fileURLWithPath: outputPath))
print("ocr_items=\(output.count) output=\(outputPath)")
