/*
 * Copyright 2025 Google LLC.
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

package hipstershop;

import io.grpc.ForwardingServerCallListener;
import io.grpc.Metadata;
import io.grpc.ServerCall;
import io.grpc.ServerCallHandler;
import io.grpc.ServerInterceptor;
import java.util.UUID;
import org.apache.logging.log4j.ThreadContext;

public class CorrelationIdServerInterceptor implements ServerInterceptor {
  private static final Metadata.Key<String> REQUEST_ID_HEADER =
      Metadata.Key.of("x-request-id", Metadata.ASCII_STRING_MARSHALLER);
  private static final Metadata.Key<String> SESSION_ID_HEADER =
      Metadata.Key.of("x-session-id", Metadata.ASCII_STRING_MARSHALLER);
  private static final Metadata.Key<String> USER_ID_HEADER =
      Metadata.Key.of("x-user-id", Metadata.ASCII_STRING_MARSHALLER);

  @Override
  public <ReqT, RespT> ServerCall.Listener<ReqT> interceptCall(
      ServerCall<ReqT, RespT> call, Metadata headers, ServerCallHandler<ReqT, RespT> next) {
    String requestId = headers.get(REQUEST_ID_HEADER);
    if (requestId == null || requestId.isEmpty()) {
      requestId = UUID.randomUUID().toString();
    }
    ThreadContext.put("request_id", requestId);

    String sessionId = headers.get(SESSION_ID_HEADER);
    if (sessionId != null && !sessionId.isEmpty()) {
      ThreadContext.put("session_id", sessionId);
    }
    String userId = headers.get(USER_ID_HEADER);
    if (userId != null && !userId.isEmpty()) {
      ThreadContext.put("user_id", userId);
    }

    ServerCall.Listener<ReqT> listener = next.startCall(call, headers);
    return new ForwardingServerCallListener.SimpleForwardingServerCallListener<>(listener) {
      @Override
      public void onComplete() {
        clearContext();
        super.onComplete();
      }

      @Override
      public void onCancel() {
        clearContext();
        super.onCancel();
      }
    };
  }

  private static void clearContext() {
    ThreadContext.remove("request_id");
    ThreadContext.remove("session_id");
    ThreadContext.remove("user_id");
  }
}
