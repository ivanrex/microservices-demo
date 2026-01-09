#!/usr/bin/python
#
# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import os
import sys
import types

sys.path.append(os.path.dirname(os.path.dirname(__file__)))

otel_module = types.ModuleType("opentelemetry")
otel_trace_module = types.ModuleType("opentelemetry.trace")
otel_trace_module.get_current_span = lambda: None
otel_module.trace = otel_trace_module
sys.modules["opentelemetry"] = otel_module
sys.modules["opentelemetry.trace"] = otel_trace_module

from logging_context import outbound_metadata, set_correlation_from_context


class FakeContext:
    def invocation_metadata(self):
        return [
            ("x-request-id", "req-123"),
            ("x-session-id", "sess-456"),
            ("x-user-id", "user-789"),
        ]


def main():
    set_correlation_from_context(FakeContext())
    metadata = dict(outbound_metadata())
    assert metadata["x-request-id"] == "req-123"
    assert metadata["x-session-id"] == "sess-456"
    assert metadata["x-user-id"] == "user-789"
    print("recommendationservice smoke test passed")


if __name__ == "__main__":
    main()
