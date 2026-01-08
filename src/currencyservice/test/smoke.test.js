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

const assert = require('assert');

const { baseLogger, loggerForCall } = require('../logging');

function mockMetadata(values) {
  return {
    get: (key) => {
      if (Object.prototype.hasOwnProperty.call(values, key)) {
        return [values[key]];
      }
      return [];
    }
  };
}

const callWithMetadata = { metadata: mockMetadata({ 'x-request-id': 'req-123', 'x-user-id': 'user-9' }) };
const child = loggerForCall(callWithMetadata);

assert.ok(baseLogger);
assert.strictEqual(typeof loggerForCall, 'function');
assert.ok(child);
assert.strictEqual(child.bindings().request_id, 'req-123');
assert.strictEqual(child.bindings().user_id, 'user-9');

const callWithoutMetadata = { metadata: mockMetadata({}) };
const childWithGenerated = loggerForCall(callWithoutMetadata);
assert.ok(childWithGenerated.bindings().request_id);

console.log('currencyservice smoke test passed');
