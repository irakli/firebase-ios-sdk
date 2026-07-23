// Copyright 2026 Google LLC
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

import FirebaseAppCheckInterop
import FirebaseAuthInterop
import FirebaseCore
import XCTest

@testable import FirebaseAILogic

#if !os(watchOS)
  @available(macOS 12.0, *)
  final class GenerativeAIServiceTests: XCTestCase {
    let testModelName = "test-model"
    let testModelResourceName =
      "projects/test-project-id/locations/test-location/publishers/google/models/test-model"
    let apiConfig = FirebaseAI.defaultVertexAIAPIConfig

    var urlSession: URLSession!
    var model: GenerativeModel!

    override func setUp() async throws {
      let configuration = URLSessionConfiguration.default
      configuration.protocolClasses = [MockURLProtocol.self]
      urlSession = try XCTUnwrap(URLSession(configuration: configuration))
      model = GenerativeModel(
        modelName: testModelName,
        modelResourceName: testModelResourceName,
        firebaseInfo: GenerativeModelTestUtil.testFirebaseInfo(),
        apiConfig: apiConfig,
        tools: nil,
        requestOptions: RequestOptions(),
        urlSession: urlSession
      )
    }

    override func tearDown() {
      MockURLProtocol.requestHandler = nil
      MockURLProtocol.errorToThrowMidStream = nil
      MockURLProtocol.stopLoadingExpectation = nil
      MockURLProtocol.neverFinishes = false
    }

    func testGenerateContent_failure_unrecognizedErrorPayload() async throws {
      let expectedStatusCode = 500
      let responseBody = "PRIVATE_RESPONSE_BODY_SENTINEL"
      let probeID = UUID().uuidString
      StreamingTestURLProtocol.register(
        id: probeID,
        mode: .complete(
          statusCode: expectedStatusCode,
          data: Data(responseBody.utf8)
        )
      )
      defer { StreamingTestURLProtocol.unregister(id: probeID) }

      do {
        _ = try await streamingModel(probeID: probeID).generateContent("test")
        XCTFail("An error should have been thrown, but no error was thrown.")
      } catch let GenerateContentError
        .internalError(underlying: unrecognizedError as UnrecognizedRPCError) {
        XCTAssertEqual(
          unrecognizedError.localizedDescription,
          "The Firebase AI service returned an unrecognized error payload."
        )
        XCTAssertFalse(unrecognizedError.localizedDescription.contains(responseBody))
      } catch {
        XCTFail("Caught unexpected error: \(error)")
      }
    }

    func testAILog_discardsCallerMessageAtActualSink() {
      let sentinels = [
        "PRIVATE_PROMPT_SENTINEL",
        "PRIVATE_IMAGE_BASE64_SENTINEL",
        "PRIVATE_PROVIDER_RESPONSE_SENTINEL",
        "PRIVATE_API_KEY_SENTINEL",
        "PRIVATE_AUTH_TOKEN_SENTINEL",
        "PRIVATE_APP_CHECK_TOKEN_SENTINEL",
      ]
      let code = AILog.MessageCode.loadRequestResponseErrorPayload
      let lock = NSLock()
      var messages: [String] = []
      let interceptorID = AILog.addLogInterceptor { _, observedCode, message in
        guard observedCode == code else { return }
        lock.lock()
        messages.append(message)
        lock.unlock()
      }
      defer { AILog.removeLogInterceptor(interceptorID) }

      AILog.error(code: code, "Sensitive values: \(sentinels.joined(separator: " "))")

      lock.lock()
      let capturedMessages = messages
      lock.unlock()
      XCTAssertEqual(capturedMessages, ["Firebase AI event \(code.rawValue)."])
      for sentinel in sentinels {
        XCTAssertFalse(capturedMessages.contains(where: { $0.contains(sentinel) }))
      }
    }

    func testGenerateContentStream_consumerCancellationStopsLoading() async throws {
      let started = expectation(description: "URL loading started")
      let stopped = expectation(description: "URL loading stopped")
      let probeID = UUID().uuidString
      StreamingTestURLProtocol.register(
        id: probeID,
        mode: .hold,
        onStart: { started.fulfill() },
        onStop: { stopped.fulfill() }
      )
      defer { StreamingTestURLProtocol.unregister(id: probeID) }

      let stream = try streamingModel(probeID: probeID)
        .generateContentStream("PRIVATE_STREAM_PROMPT_SENTINEL")
      let consumer = Task {
        for try await _ in stream {}
      }

      await fulfillment(of: [started], timeout: 2)
      consumer.cancel()
      await fulfillment(of: [stopped], timeout: 2)
      _ = await consumer.result
    }

    func testGenerateContentStream_midstreamTransportFailureTerminatesConsumer() async throws {
      let injectedError = URLError(.networkConnectionLost)
      let input = AsyncThrowingStream<String, Error> { continuation in
        continuation.yield(
          #"data: {"candidates":[{"content":{"role":"model","parts":[{"text":"partial"}]},"finishReason":"STOP","index":0}]}"#
        )
        continuation.finish(throwing: injectedError)
      }
      let probeID = UUID().uuidString
      let service = streamingService(probeID: probeID)
      let output = AsyncThrowingStream<GenerateContentResponse, Error> { continuation in
        Task {
          await service.processSuccessfulResponseLines(
            input,
            responseType: GenerateContentResponse.self,
            continuation: continuation
          )
        }
      }
      var responseTexts: [String] = []

      do {
        for try await response in output {
          if let text = response.text {
            responseTexts.append(text)
          }
        }
        XCTFail("A mid-stream transport failure should terminate with an error.")
      } catch let error as URLError {
        XCTAssertEqual(error.code, injectedError.code)
        XCTAssertEqual(responseTexts, ["partial"])
      } catch {
        XCTFail("Unexpected stream error: \(error)")
      }
    }

    func testGenerateContentStream_failure_midStreamError_throwsError() async throws {
      let expectedStatusCode = 200
      let validJSON = "{\"candidates\": [{\"content\": {\"parts\": [{\"text\": \"Hello\"}]}}]}"
      let responseBody = String(repeating: "data: \(validJSON)\n\n", count: 100)

      let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      addTeardownBlock {
        try? FileManager.default.removeItem(at: tempURL)
      }

      MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: expectedStatusCode,
          httpVersion: nil,
          headerFields: nil
        )!

        try responseBody.write(to: tempURL, atomically: true, encoding: .utf8)
        let stream = URL(fileURLWithPath: tempURL.path).lines
        return (response, stream)
      }

      // Simulate a network drop mid-stream
      MockURLProtocol.errorToThrowMidStream = URLError(.networkConnectionLost)

      let localModel = model!

      let throwsExpectation =
        XCTestExpectation(description: "Stream should throw URLError(.networkConnectionLost)")

      Task {
        do {
          let stream = try localModel.generateContentStream("test")
          for try await _ in stream {
            // Read lines
          }
          XCTFail(
            "Stream should not finish successfully; it should throw a mid-stream network error."
          )
          throwsExpectation.fulfill()
        } catch let GenerateContentError.internalError(underlying: urlError as URLError)
          where urlError.code == .networkConnectionLost {
          // This is the expected behavior.
          throwsExpectation.fulfill()
        } catch {
          XCTFail("Stream threw unexpected error: \(error)")
          throwsExpectation.fulfill()
        }
      }

      await fulfillment(of: [throwsExpectation], timeout: 4.0)
    }

    func testGenerateContentStream_failure_midStreamError_badResponse_throwsError() async throws {
      let expectedStatusCode = 400
      let validJSON = "{\"candidates\": [{\"content\": {\"parts\": [{\"text\": \"Hello\"}]}}]}"
      let responseBody = String(repeating: "data: \(validJSON)\n\n", count: 100)

      let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      addTeardownBlock {
        try? FileManager.default.removeItem(at: tempURL)
      }

      MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: expectedStatusCode,
          httpVersion: nil,
          headerFields: nil
        )!

        try responseBody.write(to: tempURL, atomically: true, encoding: .utf8)
        let stream = URL(fileURLWithPath: tempURL.path).lines
        return (response, stream)
      }

      // Simulate a network drop mid-stream while reading the error payload
      MockURLProtocol.errorToThrowMidStream = URLError(.networkConnectionLost)

      let localModel = model!

      let throwsExpectation =
        XCTestExpectation(description: "Stream should throw URLError(.networkConnectionLost)")

      Task {
        do {
          let stream = try localModel.generateContentStream("test")
          for try await _ in stream {
            // Read lines
          }
          XCTFail(
            "Stream should not finish successfully; it should throw a mid-stream network error."
          )
          throwsExpectation.fulfill()
        } catch let GenerateContentError.internalError(underlying: urlError as URLError)
          where urlError.code == .networkConnectionLost {
          // This is the expected behavior.
          throwsExpectation.fulfill()
        } catch {
          XCTFail("Stream threw unexpected error: \(error)")
          throwsExpectation.fulfill()
        }
      }

      await fulfillment(of: [throwsExpectation], timeout: 4.0)
    }

    func testGenerateContentStream_cancellation_resourceLeak() async throws {
      let expectedStatusCode = 200

      // We don't use responseBody here because we want to manually yield lines slowly
      // to test that the mock continues sending them even after the stream is cancelled.
      // But MockURLProtocol currently doesn't support manual line yielding.
      // Let's rely on the fact that if it's NOT cancelled, the Task continues doing work.
      // We can use a large payload and assert that MockURLProtocol finishes its sleep.

      let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      addTeardownBlock {
        try? FileManager.default.removeItem(at: tempURL)
      }

      MockURLProtocol.requestHandler = { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: expectedStatusCode,
          httpVersion: nil,
          headerFields: nil
        )!

        let validJSON = "{\"candidates\": [{\"content\": {\"parts\": [{\"text\": \"Hello\"}]}}]}"
        let responseBody = String(repeating: "data: \(validJSON)\n\n", count: 100)
        try responseBody.write(to: tempURL, atomically: true, encoding: .utf8)
        let stream = URL(fileURLWithPath: tempURL.path).lines
        return (response, stream)
      }

      // Prevent the mock server from finishing naturally so it keeps the connection open.
      MockURLProtocol.neverFinishes = true

      let stopLoadingExpectation =
        XCTestExpectation(description: "stopLoading should be called when task is cancelled")
      MockURLProtocol.stopLoadingExpectation = stopLoadingExpectation

      let localModel = model!

      do {
        let stream = try localModel.generateContentStream("test")
        var iterator = stream.makeAsyncIterator()
        // Read just one item, then stop (which drops the iterator and cancels the stream)
        _ = try await iterator.next()
      } catch {
        XCTFail("Unexpected error: \(error)")
      }

      // Dropping the iterator cancels the stream. This cancellation should propagate
      // down to the underlying URLSession task, instantly calling stopLoading().

      await fulfillment(of: [stopLoadingExpectation], timeout: 2.0)
    }

    private func streamingModel(probeID: String) -> GenerativeModel {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [StreamingTestURLProtocol.self]
      let session = URLSession(configuration: configuration)
      return GenerativeModel(
        modelName: testModelName,
        modelResourceName: testModelResourceName,
        firebaseInfo: GenerativeModelTestUtil.testFirebaseInfo(apiKey: probeID),
        apiConfig: apiConfig,
        tools: nil,
        requestOptions: RequestOptions(),
        urlSession: session
      )
    }

    private func streamingService(probeID: String) -> GenerativeAIService {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [StreamingTestURLProtocol.self]
      let session = URLSession(configuration: configuration)
      return GenerativeAIService(
        firebaseInfo: GenerativeModelTestUtil.testFirebaseInfo(apiKey: probeID),
        urlSession: session
      )
    }
  }
#endif // !os(watchOS)
