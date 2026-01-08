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

package main

import (
	"context"

	"github.com/sirupsen/logrus"
	"go.opentelemetry.io/otel/trace"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

const (
	headerRequestID = "x-request-id"
	headerSessionID = "x-session-id"
	headerUserID    = "x-user-id"
)

type correlationInfo struct {
	RequestID string
	SessionID string
	UserID    string
}

func correlationFromContext(ctx context.Context) correlationInfo {
	var info correlationInfo
	if v, ok := ctx.Value(ctxKeyRequestID{}).(string); ok {
		info.RequestID = v
	}
	if v, ok := ctx.Value(ctxKeySessionID{}).(string); ok {
		info.SessionID = v
		if info.UserID == "" {
			info.UserID = v
		}
	}
	if v, ok := ctx.Value(ctxKeyUserID{}).(string); ok {
		info.UserID = v
	}
	return info
}

func contextWithCorrelation(ctx context.Context, info correlationInfo) context.Context {
	if info.RequestID != "" {
		ctx = context.WithValue(ctx, ctxKeyRequestID{}, info.RequestID)
	}
	if info.SessionID != "" {
		ctx = context.WithValue(ctx, ctxKeySessionID{}, info.SessionID)
	}
	if info.UserID != "" {
		ctx = context.WithValue(ctx, ctxKeyUserID{}, info.UserID)
	}
	return ctx
}

func logFieldsFromContext(ctx context.Context) logrus.Fields {
	fields := logrus.Fields{}
	info := correlationFromContext(ctx)
	if info.RequestID != "" {
		fields["request_id"] = info.RequestID
	}
	if info.SessionID != "" {
		fields["session_id"] = info.SessionID
	}
	if info.UserID != "" {
		fields["user_id"] = info.UserID
	}

	span := trace.SpanFromContext(ctx)
	if span != nil {
		spanCtx := span.SpanContext()
		if spanCtx.IsValid() {
			fields["trace_id"] = spanCtx.TraceID().String()
			fields["span_id"] = spanCtx.SpanID().String()
		}
	}
	return fields
}

func grpcUnaryClientInterceptor() grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply interface{}, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		info := correlationFromContext(ctx)
		md, _ := metadata.FromOutgoingContext(ctx)
		if md == nil {
			md = metadata.New(nil)
		}
		if info.RequestID != "" {
			md.Set(headerRequestID, info.RequestID)
		}
		if info.SessionID != "" {
			md.Set(headerSessionID, info.SessionID)
		}
		if info.UserID != "" {
			md.Set(headerUserID, info.UserID)
		}
		ctx = metadata.NewOutgoingContext(ctx, md)
		return invoker(ctx, method, req, reply, cc, opts...)
	}
}
