// Copyright 2025 Google LLC
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

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Grpc.Core;
using Grpc.Core.Interceptors;
using Microsoft.Extensions.Logging;

namespace cartservice
{
    public class CorrelationIdInterceptor : Interceptor
    {
        private readonly ILogger<CorrelationIdInterceptor> _logger;

        public CorrelationIdInterceptor(ILogger<CorrelationIdInterceptor> logger)
        {
            _logger = logger;
        }

        public override async Task<TResponse> UnaryServerHandler<TRequest, TResponse>(
            TRequest request,
            ServerCallContext context,
            UnaryServerMethod<TRequest, TResponse> continuation)
        {
            var requestId = GetHeaderValue(context, "x-request-id") ?? Guid.NewGuid().ToString();
            var sessionId = GetHeaderValue(context, "x-session-id");
            var userId = GetHeaderValue(context, "x-user-id");

            var scope = new Dictionary<string, object>
            {
                ["request_id"] = requestId
            };

            if (!string.IsNullOrEmpty(sessionId))
            {
                scope["session_id"] = sessionId;
            }

            if (!string.IsNullOrEmpty(userId))
            {
                scope["user_id"] = userId;
            }

            using (_logger.BeginScope(scope))
            {
                return await continuation(request, context);
            }
        }

        private static string GetHeaderValue(ServerCallContext context, string key)
        {
            var entry = context.RequestHeaders.FirstOrDefault(
                header => string.Equals(header.Key, key, StringComparison.OrdinalIgnoreCase));
            return entry?.Value;
        }
    }
}
