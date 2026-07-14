// Copyright 2024 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif
#if canImport(CoreImage)
  import CoreImage
#endif // canImport(CoreImage)

@testable import FirebaseAILogic

final class PartsRepresentableTests: XCTestCase {
  #if !os(watchOS)
    func testModelContentFromCGImageUsesConfiguredJPEGCompressionQuality() throws {
      let image = try makeCGImage(width: 128, height: 128)

      let modelContent = image.partsValue

      XCTAssertEqual(modelContent.count, 1)
      let imagePart = try XCTUnwrap(modelContent.first as? InlineDataPart)
      XCTAssertEqual(imagePart.mimeType, "image/jpeg")
      XCTAssertEqual(imagePart.data, try jpegData(from: image, compressionQuality: 0.8))

      let source = try XCTUnwrap(CGImageSourceCreateWithData(imagePart.data as CFData, nil))
      let decodedImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
      XCTAssertEqual(decodedImage.width, image.width)
      XCTAssertEqual(decodedImage.height, image.height)
    }

    private func makeCGImage(width: Int, height: Int) throws -> CGImage {
      var pixels = [UInt8](repeating: 0, count: width * height * 4)
      for y in 0 ..< height {
        for x in 0 ..< width {
          let offset = (y * width + x) * 4
          pixels[offset] = UInt8((x * 37 + y * 11) % 256)
          pixels[offset + 1] = UInt8((x * 13 + y * 29) % 256)
          pixels[offset + 2] = UInt8((x * 7 + y * 43) % 256)
          pixels[offset + 3] = 255
        }
      }
      let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
      let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
      return try XCTUnwrap(CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
      ))
    }

    private func jpegData(from image: CGImage, compressionQuality: CGFloat) throws -> Data {
      let output = NSMutableData()
      let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
        output,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      ))
      CGImageDestinationAddImage(destination, image, [
        kCGImageDestinationLossyCompressionQuality: compressionQuality,
      ] as CFDictionary)
      XCTAssertTrue(CGImageDestinationFinalize(destination))
      return output as Data
    }
  #endif // !os(watchOS)

  #if canImport(CoreImage)
    func testModelContentFromCIImageIsNotEmpty() throws {
      let image = CIImage(color: CIColor.red)
        .cropped(to: CGRect(origin: CGPointZero, size: CGSize(width: 16, height: 16)))
      let modelContent = image.partsValue
      XCTAssert(modelContent.count > 0, "Expected non-empty model content for CGImage: \(image)")
    }

    func testModelContentFromInvalidCIImageThrows() throws {
      let image = CIImage.empty()
      let modelContent = image.partsValue
      let part = try XCTUnwrap(modelContent.first)
      let errorPart = try XCTUnwrap(part as? ErrorPart, "Expected ErrorPart.")
      let imageError = try XCTUnwrap(
        errorPart.error as? ImageConversionError,
        "Got unexpected error type: \(errorPart.error)"
      )
      guard case .couldNotConvertToJPEG = imageError else {
        XCTFail("Expected JPEG conversion error, got \(imageError) instead.")
        return
      }
    }
  #endif // canImport(CoreImage)

  #if canImport(UIKit) && !os(visionOS) // These tests are stalling in CI on visionOS.
    func testModelContentFromInvalidUIImageThrows() throws {
      let image = UIImage()
      let modelContent = image.partsValue
      let part = try XCTUnwrap(modelContent.first)
      let errorPart = try XCTUnwrap(part as? ErrorPart, "Expected ErrorPart.")
      let imageError = try XCTUnwrap(
        errorPart.error as? ImageConversionError,
        "Got unexpected error type: \(errorPart.error)"
      )
      guard case .couldNotConvertToJPEG = imageError else {
        XCTFail("Expected JPEG conversion error, got \(imageError) instead.")
        return
      }
    }

    func testModelContentFromUIImageIsNotEmpty() throws {
      let image = try XCTUnwrap(UIImage(systemName: "star.fill"))
      let modelContent = image.partsValue
      XCTAssert(modelContent.count > 0, "Expected non-empty model content for UIImage: \(image)")
    }

  #elseif canImport(AppKit)
    func testModelContentFromNSImageIsNotEmpty() throws {
      let coreImage = CIImage(color: CIColor.red)
        .cropped(to: CGRect(origin: CGPointZero, size: CGSize(width: 16, height: 16)))
      let rep = NSCIImageRep(ciImage: coreImage)
      let image = NSImage(size: rep.size)
      image.addRepresentation(rep)
      let modelContent = image.partsValue
      XCTAssert(modelContent.count > 0, "Expected non-empty model content for NSImage: \(image)")
    }

    func testModelContentFromInvalidNSImageThrows() throws {
      let image = NSImage()
      let modelContent = image.partsValue
      let part = try XCTUnwrap(modelContent.first)
      let errorPart = try XCTUnwrap(part as? ErrorPart, "Expected ErrorPart.")
      let imageError = try XCTUnwrap(
        errorPart.error as? ImageConversionError,
        "Got unexpected error type: \(errorPart.error)"
      )
      guard case .invalidUnderlyingImage = imageError else {
        XCTFail("Expected invalid underlying image conversion error, got \(imageError) instead.")
        return
      }
    }
  #endif

  func testMixedParts() throws {
    let text = "This is a test"
    let data = try XCTUnwrap("This is some data".data(using: .utf8))
    let inlineData = InlineDataPart(data: data, mimeType: "text/plain")

    let parts: [any PartsRepresentable] = [text, inlineData]
    let modelContent = ModelContent(parts: parts)

    XCTAssertEqual(modelContent.parts.count, 2)
    let textPart = try XCTUnwrap(modelContent.parts[0] as? TextPart)
    XCTAssertEqual(textPart.text, text)
    let dataPart = try XCTUnwrap(modelContent.parts[1] as? InlineDataPart)
    XCTAssertEqual(dataPart, inlineData)
  }

  #if canImport(UIKit)
    func testMixedParts_withImage() throws {
      let text = "This is a test"
      let image = try XCTUnwrap(UIImage(systemName: "star"))
      let parts: [any PartsRepresentable] = [text, image]
      let modelContent = ModelContent(parts: parts)

      XCTAssertEqual(modelContent.parts.count, 2)
      let textPart = try XCTUnwrap(modelContent.parts[0] as? TextPart)
      XCTAssertEqual(textPart.text, text)
      let imagePart = try XCTUnwrap(modelContent.parts[1] as? InlineDataPart)
      XCTAssertEqual(imagePart.mimeType, "image/jpeg")
      XCTAssertFalse(imagePart.data.isEmpty)
    }

  #elseif canImport(AppKit)
    func testMixedParts_withImage() throws {
      let text = "This is a test"
      let coreImage = CIImage(color: CIColor.blue)
        .cropped(to: CGRect(origin: CGPoint.zero, size: CGSize(width: 16, height: 16)))
      let rep = NSCIImageRep(ciImage: coreImage)
      let image = NSImage(size: rep.size)
      image.addRepresentation(rep)

      let parts: [any PartsRepresentable] = [text, image]
      let modelContent = ModelContent(parts: parts)

      XCTAssertEqual(modelContent.parts.count, 2)
      let textPart = try XCTUnwrap(modelContent.parts[0] as? TextPart)
      XCTAssertEqual(textPart.text, text)
      let imagePart = try XCTUnwrap(modelContent.parts[1] as? InlineDataPart)
      XCTAssertEqual(imagePart.mimeType, "image/jpeg")
      XCTAssertFalse(imagePart.data.isEmpty)
    }
  #endif
}
