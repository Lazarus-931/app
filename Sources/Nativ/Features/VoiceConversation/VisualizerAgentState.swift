/*
 * Original work Copyright 2024 LiveKit, Inc.
 * Modifications Copyright 2025 Eleven Labs Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Vendored from ElevenLabs components-swift (Apache-2.0). The LiveKit
// `init(from: AgentState)` convenience was dropped — Nativ drives these states
// from its own conversation controller, not a LiveKit session.

import Foundation

/// The state a conversational agent is in, used to drive the orb's animation.
public enum VisualizerAgentState: Sendable, Equatable {
    /// Agent is connecting to the session
    case connecting
    /// Agent is initializing
    case initializing
    /// Agent is listening to user input
    case listening
    /// Agent is processing/thinking
    case thinking
    /// Agent is speaking
    case speaking
    /// Agent is disconnected
    case disconnected
    /// Unknown or unspecified state
    case unknown
}
