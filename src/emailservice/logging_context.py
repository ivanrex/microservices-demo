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

import contextvars
from uuid import uuid4

from opentelemetry import trace

_correlation_ctx = contextvars.ContextVar("correlation_ctx", default={})

HEADER_REQUEST_ID = "x-request-id"
HEADER_SESSION_ID = "x-session-id"
HEADER_USER_ID = "x-user-id"


def set_correlation_from_context(grpc_context):
  metadata = {}
  for key, value in grpc_context.invocation_metadata():
    metadata[key] = value

  request_id = metadata.get(HEADER_REQUEST_ID) or str(uuid4())
  session_id = metadata.get(HEADER_SESSION_ID)
  user_id = metadata.get(HEADER_USER_ID)

  _correlation_ctx.set({
    "request_id": request_id,
    "session_id": session_id,
    "user_id": user_id
  })


def get_correlation():
  return _correlation_ctx.get()


def outbound_metadata():
  correlation = get_correlation()
  metadata = []
  if correlation.get("request_id"):
    metadata.append((HEADER_REQUEST_ID, correlation["request_id"]))
  if correlation.get("session_id"):
    metadata.append((HEADER_SESSION_ID, correlation["session_id"]))
  if correlation.get("user_id"):
    metadata.append((HEADER_USER_ID, correlation["user_id"]))
  return metadata


class CorrelationFilter:
  def filter(self, record):
    correlation = get_correlation()
    for key in ("request_id", "session_id", "user_id"):
      value = correlation.get(key)
      if value:
        setattr(record, key, value)

    span = trace.get_current_span()
    if span:
      span_ctx = span.get_span_context()
      if span_ctx and span_ctx.is_valid:
        record.trace_id = format(span_ctx.trace_id, "032x")
        record.span_id = format(span_ctx.span_id, "016x")
    return True
