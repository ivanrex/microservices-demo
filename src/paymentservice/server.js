// Copyright 2018 Google LLC
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

const path = require('path');
const grpc = require('@grpc/grpc-js');
const protoLoader = require('@grpc/proto-loader');

const charge = require('./charge');
const { businessEventLogger } = require('./events');

const logger = require('./logger')

class HipsterShopServer {
  constructor(protoRoot, port = HipsterShopServer.PORT) {
    this.port = port;

    this.packages = {
      hipsterShop: this.loadProto(path.join(protoRoot, 'demo.proto')),
      health: this.loadProto(path.join(protoRoot, 'grpc/health/v1/health.proto'))
    };

    this.server = new grpc.Server();
    this.loadAllProtos(protoRoot);
  }

  /**
   * Handler for PaymentService.Charge.
   * @param {*} call  { ChargeRequest }
   * @param {*} callback  fn(err, ChargeResponse)
   */
  static ChargeServiceHandler(call, callback) {
    const reqLogger = logger.withRequestContext(call.metadata);
    const amount = call.request && call.request.amount;
    try {
      reqLogger.info(`PaymentService#Charge invoked with request ${JSON.stringify(call.request)}`);
      businessEventLogger(reqLogger, 'payment_charge_requested', 'charge_card', 'payment', 'charge', 'success', {
        amount_currency: amount ? amount.currency_code : undefined,
        amount_units: amount ? amount.units : undefined
      }).info('payment charge requested');
      const response = charge(call.request, reqLogger);
      businessEventLogger(reqLogger, 'payment_charge_succeeded', 'charge_card', 'payment', 'charge', 'success', {
        payment_txn_id: response.transaction_id,
        amount_currency: amount ? amount.currency_code : undefined,
        amount_units: amount ? amount.units : undefined
      }).info('payment charge succeeded');
      callback(null, response);
    } catch (err) {
      businessEventLogger(reqLogger, 'payment_charge_failed', 'charge_card', 'payment', 'charge', 'failure', {
        amount_currency: amount ? amount.currency_code : undefined,
        amount_units: amount ? amount.units : undefined
      }).warn({ err }, 'payment charge failed');
      console.warn(err);
      callback(err);
    }
  }

  static CheckHandler(call, callback) {
    callback(null, { status: 'SERVING' });
  }


  listen() {
    const server = this.server 
    const port = this.port
    server.bindAsync(
      `[::]:${port}`,
      grpc.ServerCredentials.createInsecure(),
      function () {
        logger.info(`PaymentService gRPC server started on port ${port}`);
        server.start();
      }
    );
  }

  loadProto(path) {
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

  loadAllProtos(protoRoot) {
    const hipsterShopPackage = this.packages.hipsterShop.hipstershop;
    const healthPackage = this.packages.health.grpc.health.v1;

    this.server.addService(
      hipsterShopPackage.PaymentService.service,
      {
        charge: HipsterShopServer.ChargeServiceHandler.bind(this)
      }
    );

    this.server.addService(
      healthPackage.Health.service,
      {
        check: HipsterShopServer.CheckHandler.bind(this)
      }
    );
  }
}

HipsterShopServer.PORT = process.env.PORT;

module.exports = HipsterShopServer;
