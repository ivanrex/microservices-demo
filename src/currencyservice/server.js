/*
 * Copyright 2018 Google LLC.
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

const { baseLogger, loggerForCall, businessEventLogger } = require('./logging');
const logger = baseLogger;

if(process.env.DISABLE_PROFILER) {
  logger.info("Profiler disabled.")
}
else {
  logger.info("Profiler enabled.")
  require('@google-cloud/profiler').start({
    serviceContext: {
      service: 'currencyservice',
      version: '1.0.0'
    }
  });
}

// Register GRPC OTel Instrumentation for trace propagation
// regardless of whether tracing is emitted.
const { GrpcInstrumentation } = require('@opentelemetry/instrumentation-grpc');
const { registerInstrumentations } = require('@opentelemetry/instrumentation');

registerInstrumentations({
  instrumentations: [new GrpcInstrumentation()]
});

if(process.env.ENABLE_TRACING == "1") {
  logger.info("Tracing enabled.")

  const { resourceFromAttributes } = require('@opentelemetry/resources');

  const { ATTR_SERVICE_NAME } = require('@opentelemetry/semantic-conventions');

  const opentelemetry = require('@opentelemetry/sdk-node');

  const { OTLPTraceExporter } = require('@opentelemetry/exporter-otlp-grpc');

  const collectorUrl = process.env.COLLECTOR_SERVICE_ADDR;
  const traceExporter = new OTLPTraceExporter({url: collectorUrl});
  const sdk = new opentelemetry.NodeSDK({
    resource: resourceFromAttributes({
      [ ATTR_SERVICE_NAME ]: process.env.OTEL_SERVICE_NAME || 'currencyservice',
    }),
    traceExporter: traceExporter,
  });

  sdk.start()
}
else {
  logger.info("Tracing disabled.")
}

const path = require('path');
const grpc = require('@grpc/grpc-js');
const protoLoader = require('@grpc/proto-loader');

const MAIN_PROTO_PATH = path.join(__dirname, './proto/demo.proto');
const HEALTH_PROTO_PATH = path.join(__dirname, './proto/grpc/health/v1/health.proto');

const PORT = process.env.PORT;

const shopProto = _loadProto(MAIN_PROTO_PATH).hipstershop;
const healthProto = _loadProto(HEALTH_PROTO_PATH).grpc.health.v1;

/**
 * Helper function that loads a protobuf file.
 */
function _loadProto (path) {
  const packageDefinition = protoLoader.loadSync(
    path,
    {
      keepCase: true,
      longs: String,
      enums: String,
      defaults: true,
      oneofs: true
    }
  );
  return grpc.loadPackageDefinition(packageDefinition);
}

/**
 * Helper function that gets currency data from a stored JSON file
 * Uses public data from European Central Bank
 */
function _getCurrencyData (callback) {
  const data = require('./data/currency_conversion.json');
  callback(data);
}

/**
 * Helper function that handles decimal/fractional carrying
 */
function _carry (amount) {
  const fractionSize = Math.pow(10, 9);
  amount.nanos += (amount.units % 1) * fractionSize;
  amount.units = Math.floor(amount.units) + Math.floor(amount.nanos / fractionSize);
  amount.nanos = amount.nanos % fractionSize;
  return amount;
}

/**
 * Lists the supported currencies
 */
function getSupportedCurrencies (call, callback) {
  const reqLogger = loggerForCall(call);
  reqLogger.info('Getting supported currencies...');
  businessEventLogger(reqLogger, 'currency_list_requested', 'list_currencies', 'currency', 'get_supported_currencies', 'success')
    .info('currency list requested');
  _getCurrencyData((data) => {
    businessEventLogger(reqLogger, 'currency_list_returned', 'list_currencies', 'currency', 'get_supported_currencies', 'success', {
      currency_count: Object.keys(data).length
    }).info('currency list returned');
    callback(null, {currency_codes: Object.keys(data)});
  });
}

/**
 * Converts between currencies
 */
function convert (call, callback) {
  const reqLogger = loggerForCall(call);
  try {
    _getCurrencyData((data) => {
      const request = call.request;
      businessEventLogger(reqLogger, 'currency_convert_requested', 'convert_currency', 'currency', 'convert', 'success', {
        from_currency: request.from.currency_code,
        to_currency: request.to_code
      }).info('currency convert requested');

      // Convert: from_currency --> EUR
      const from = request.from;
      const euros = _carry({
        units: from.units / data[from.currency_code],
        nanos: from.nanos / data[from.currency_code]
      });

      euros.nanos = Math.round(euros.nanos);

      // Convert: EUR --> to_currency
      const result = _carry({
        units: euros.units * data[request.to_code],
        nanos: euros.nanos * data[request.to_code]
      });

      result.units = Math.floor(result.units);
      result.nanos = Math.floor(result.nanos);
      result.currency_code = request.to_code;

      reqLogger.info(`conversion request successful`);
      businessEventLogger(reqLogger, 'currency_convert_succeeded', 'convert_currency', 'currency', 'convert', 'success', {
        from_currency: request.from.currency_code,
        to_currency: request.to_code
      }).info('currency convert succeeded');
      callback(null, result);
    });
  } catch (err) {
    businessEventLogger(reqLogger, 'currency_convert_failed', 'convert_currency', 'currency', 'convert', 'failure', {
      error: err.message || String(err)
    }).warn('currency convert failed');
    reqLogger.error(`conversion request failed: ${err}`);
    callback(err.message);
  }
}

/**
 * Endpoint for health checks
 */
function check (call, callback) {
  callback(null, { status: 'SERVING' });
}

/**
 * Starts an RPC server that receives requests for the
 * CurrencyConverter service at the sample server port
 */
function main () {
  logger.info(`Starting gRPC server on port ${PORT}...`);
  const server = new grpc.Server();
  server.addService(shopProto.CurrencyService.service, {getSupportedCurrencies, convert});
  server.addService(healthProto.Health.service, {check});

  server.bindAsync(
    `[::]:${PORT}`,
    grpc.ServerCredentials.createInsecure(),
    function() {
      logger.info(`CurrencyService gRPC server started on port ${PORT}`);
      server.start();
    },
   );
}

main();
