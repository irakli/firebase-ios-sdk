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

import Foundation
import XCTest

#if !os(watchOS)
  @available(macOS 12.0, *)
  final class StreamingTestURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode {
      case hold
      case respondThenHold(Data)
      case complete(statusCode: Int, data: Data)
    }

    private final class State {
      let mode: Mode
      let onStart: () -> Void
      let onStop: () -> Void

      init(mode: Mode,
           onStart: @escaping () -> Void,
           onStop: @escaping () -> Void) {
        self.mode = mode
        self.onStart = onStart
        self.onStop = onStop
      }
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var states: [String: State] = [:]
    private var activeState: State?

    static func register(id: String,
                         mode: Mode,
                         onStart: @escaping () -> Void = {},
                         onStop: @escaping () -> Void = {}) {
      lock.lock()
      states[id] = State(mode: mode, onStart: onStart, onStop: onStop)
      lock.unlock()
    }

    static func unregister(id: String) {
      lock.lock()
      states[id] = nil
      lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
      return state(for: request) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
      return request
    }

    override func startLoading() {
      guard let client, let state = Self.state(for: request) else {
        XCTFail("Streaming test protocol was not registered for this request.")
        return
      }
      activeState = state
      state.onStart()
      let response = HTTPURLResponse(
        url: request.url!,
        statusCode: state.mode.statusCode,
        httpVersion: nil,
        headerFields: nil
      )!
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

      switch state.mode {
      case .hold:
        return
      case let .respondThenHold(data):
        client.urlProtocol(self, didLoad: data)
      case let .complete(_, data):
        client.urlProtocol(self, didLoad: data)
        client.urlProtocolDidFinishLoading(self)
      }
    }

    override func stopLoading() {
      activeState?.onStop()
    }

    private static func state(for request: URLRequest) -> State? {
      guard let id = request.value(forHTTPHeaderField: "x-goog-api-key") else {
        return nil
      }
      lock.lock()
      defer { lock.unlock() }
      return states[id]
    }
  }

  private extension StreamingTestURLProtocol.Mode {
    var statusCode: Int {
      switch self {
      case .hold, .respondThenHold:
        return 200
      case let .complete(statusCode, _):
        return statusCode
      }
    }
  }
#endif // !os(watchOS)
