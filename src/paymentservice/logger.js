/*
 * Copyright 2023 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

const { randomUUID } = require('crypto');
const pino = require('pino');

const logger = pino({
  name: 'paymentservice-server',
  messageKey: 'message',
  formatters: {
    level (logLevelString, logLevelNum) {
      return { severity: logLevelString }
    }
  }
});

const HEADER_REQUEST_ID = 'x-request-id';
const HEADER_SESSION_ID = 'x-session-id';
const HEADER_USER_ID = 'x-user-id';

function getMetadataValue(metadata, key) {
  if (!metadata || typeof metadata.get !== 'function') {
    return undefined;
  }
  const values = metadata.get(key);
  if (!values || values.length === 0) {
    return undefined;
  }
  return values[0];
}

logger.withRequestContext = function withRequestContext(metadata) {
  const requestId = getMetadataValue(metadata, HEADER_REQUEST_ID) || randomUUID();
  const sessionId = getMetadataValue(metadata, HEADER_SESSION_ID);
  const userId = getMetadataValue(metadata, HEADER_USER_ID);
  return logger.child({
    request_id: requestId,
    session_id: sessionId,
    user_id: userId
  });
};

module.exports = logger;
