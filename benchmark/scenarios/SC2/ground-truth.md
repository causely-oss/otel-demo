# SC2 Ground Truth: Payment Service Fraud Check Misconfiguration

## Root Cause
- **Primary entity:** otel-demo/payment
- **Fault type:** Application error — misconfigured constant causes every charge to be rejected by the fraud check
- **Description:** `charge.js` introduces a `runFraudCheck` function that scores each transaction against `FRAUD_RISK_THRESHOLD`. The threshold is set to `0.0` (should be `0.8`) — a constant that was zeroed out during a config refactor and not caught in review. Since every transaction produces a score above 0.0, every charge is rejected with an error. Payment returns a gRPC `INTERNAL` error on every call, checkout fails to place any order, and frontend surfaces checkout failures to users. The payment pod itself stays alive, passes health checks, and shows no signs of infrastructure failure — making it non-obvious as the root cause.
- **Useful telemetry:** every failed charge emits an `ERROR` pino log with `riskScore`, `threshold: 0`, and the message `"SC2 fraud check rejected transaction: risk score exceeds threshold"`. This surfaces in Causely evidence and directly identifies both the fault (`FRAUD_RISK_THRESHOLD = 0.0`) and the fix location (`charge.js`).

## Detection Timeline
- **~9–11 min after inject:** error rate crosses threshold, `RequestErrorRate_High` fires on payment, checkout, and frontend simultaneously
- **~1–2 min later:** Causely identifies RC (`Service Malfunction` on `otel-demo/payment`)
- **Total time to diagnosis: ~10–14 minutes from fault injection**

## Signal Chain (how Causely detects it)
1. `RequestErrorRate_High` on `otel-demo/payment` — every charge returns an error
2. `RequestErrorRate_High` on `otel-demo/checkout` — PlaceOrder fails on every payment call
3. `RequestErrorRate_High` on `otel-demo/frontend` — checkout failures propagate to users
4. RC: `Service Malfunction` attributed to `otel-demo/payment`
5. Evidence logs: ERROR lines with `riskScore` and `threshold: 0` pointing directly to `FRAUD_RISK_THRESHOLD` in `charge.js`

## Blast Radius
- **Primary:** otel-demo/payment (error source)
- **Secondary:** otel-demo/checkout (all PlaceOrder calls fail)
- **Tertiary:** otel-demo/frontend (all checkout attempts fail for users)

## Why This Is Difficult to Diagnose Without Causal Topology
- Payment pod is running, healthy, no restarts — infrastructure monitoring shows nothing wrong
- Errors surface first and most visibly on checkout and frontend, not payment
- Checkout logs show `"rpc error: INTERNAL"` from payment — could be misread as a checkout bug, a network issue, or a payment infrastructure problem
- Without the dependency graph an AI SRE investigates checkout first, finds no internal logic errors, and must trace back through the call chain to payment
- Even reaching payment, the error message references a `fraud check` — an AI SRE without code access might escalate to an infrastructure or security team rather than identifying it as a misconfigured constant in `charge.js`
- With Causely: payment is the RC entity, checkout and frontend are correctly identified as downstream victims, and log evidence with `threshold: 0` makes the fix unambiguous

## What Is NOT the Root Cause
- otel-demo/checkout — PlaceOrder errors are caused entirely by payment rejecting every charge
- otel-demo/frontend — downstream impact of checkout failures
- otel-demo/cart, otel-demo/currency, otel-demo/shipping — unaffected

## Realistic Remediation
1. Causely surfaces RC on `otel-demo/payment` with log evidence showing `riskScore: 0.4xx, threshold: 0`.
2. Developer opens `charge.js`, finds `const FRAUD_RISK_THRESHOLD = 0.0` — immediately clear this is wrong.
3. Fix: restore `FRAUD_RISK_THRESHOLD = 0.8` (or load from environment config to prevent recurrence).
4. Deploy fix, confirm `RequestErrorRate_High` clears on payment, checkout, and frontend.
5. Post-incident: add a config validation check to catch threshold values outside expected range on startup.
