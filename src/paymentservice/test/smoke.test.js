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

const logger = require('../logger');
const { businessEventLogger } = require('../events');

const reqLogger = logger.withRequestContext({
  get: (key) => {
    if (key === 'x-request-id') return ['req-123'];
    if (key === 'x-user-id') return ['user-42'];
    return [];
  }
});

const eventLogger = businessEventLogger(
  reqLogger,
  'payment_charge_requested',
  'charge_card',
  'payment',
  'charge',
  'success',
  { amount_units: 10 }
);

assert.strictEqual(reqLogger.bindings().request_id, 'req-123');
assert.strictEqual(reqLogger.bindings().user_id, 'user-42');
assert.strictEqual(eventLogger.bindings().event, 'payment_charge_requested');
assert.strictEqual(eventLogger.bindings().service, 'paymentservice');
assert.strictEqual(eventLogger.bindings().amount_units, 10);

console.log('paymentservice smoke test passed');
