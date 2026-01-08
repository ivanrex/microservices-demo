# Logging Semantics

## Goal
Provide consistent, structured logs across Online Boutique services so request flows can be reconstructed end-to-end.

## Correlation propagation
- HTTP ingress: accept `x-request-id` if present, otherwise generate one and return it in the response header.
- gRPC: propagate `x-request-id` across all service calls using gRPC metadata.
- Optional identity fields:
  - `x-session-id` for browser session correlation
  - `x-user-id` for authenticated users (or anonymized identifier)

## Structured schema (JSON)
All services should emit logs with these common keys whenever possible:
- `event`: business event name (string)
- `service`: service name (string)
- `component`: subsystem or handler (string)
- `severity`: log level (string)
- `request_id` (or `trace_id`): correlation identifier
- `span_id`: trace span ID when available
- `session_id`: session identifier when available
- `user_id`: user identifier when available
- `action`: what the user or system did (string)
- `entity`: domain object (cart, order, product, payment, shipment)
- `outcome`: `success` or `failure`
- `reason`: short trigger, e.g. `checkout`, `place_order`, `send_order_confirmation_email`
- Domain IDs when known: `order_id`, `cart_id`, `product_id`, `payment_txn_id`

## Example logs
### HTTP ingress
```json
{
  "timestamp": "2025-01-01T12:00:00Z",
  "severity": "INFO",
  "service": "frontend",
  "component": "http",
  "event": "place_order",
  "request_id": "9f6c1c02-45ab-4a8f-9b7a-9b71d9f4a7b0",
  "session_id": "12345678-1234-1234-1234-123456789123",
  "user_id": "12345678-1234-1234-1234-123456789123",
  "action": "place_order",
  "entity": "order",
  "outcome": "success"
}
```

### Downstream gRPC call
```json
{
  "timestamp": "2025-01-01T12:00:01Z",
  "severity": "INFO",
  "service": "checkoutservice",
  "component": "grpc",
  "event": "payment_authorized",
  "request_id": "9f6c1c02-45ab-4a8f-9b7a-9b71d9f4a7b0",
  "trace_id": "1e2f3a4b5c6d7e8f9a0b1c2d3e4f5678",
  "span_id": "7f6e5d4c3b2a1908",
  "action": "charge_card",
  "entity": "payment",
  "payment_txn_id": "a9c2f4e7-2f7d-4a55-9d1c-8b9c5f6a0e8a",
  "outcome": "success"
}
```
