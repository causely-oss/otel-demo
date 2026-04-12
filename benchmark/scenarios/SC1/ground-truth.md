# SC1 Ground Truth: Application Regression

## Root Cause
- **Primary entity:** otel-demo/checkout
- **Fault type:** ApplicationLogicRegression
- **Description:** Go array index out of bounds panic in `PlaceOrder()` when the order contains a single item. The bundle-selection optimization accesses `prep.orderItems[1]` without bounds checking.

## Blast Radius
- **Primary:** otel-demo/checkout
- **Secondary:** otel-demo/frontend-proxy
- **Supporting entities:** oteldemo.CheckoutService/PlaceOrder, /api/checkout

## What is NOT the root cause
- otel-demo/frontend-proxy
- otel-demo/payment
- otel-demo/postgresql

## Remediation
1. Roll back checkout to the configured base image.
2. Or fix `src/checkout/main.go` to bounds-check before accessing `orderItems[1]`.
3. Stop the sustained scenario traffic.
