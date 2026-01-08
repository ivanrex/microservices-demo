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

import "github.com/sirupsen/logrus"

const (
	frontendServiceName = "frontend"
	frontendComponent   = "http"
)

func businessEventLogger(
	log logrus.FieldLogger,
	event string,
	action string,
	entity string,
	reason string,
	outcome string,
	extra logrus.Fields,
) logrus.FieldLogger {
	fields := logrus.Fields{
		"event":     event,
		"service":   frontendServiceName,
		"component": frontendComponent,
		"action":    action,
		"entity":    entity,
	}
	if reason != "" {
		fields["reason"] = reason
	}
	if outcome != "" {
		fields["outcome"] = outcome
	}
	for key, value := range extra {
		fields[key] = value
	}
	return log.WithFields(fields)
}
