# OTel Demo for Causely

This project provides all the configurations needed to deploy the [OpenTelemetry Demo](https://opentelemetry.io/docs/demo/)
without the out of the box observability stack (Prometheus, Jaeger, Grafana, OpenSearch) and a custom OpenTelemetry collector configuration.

By default the configuration is for ingesting telemetry into the [Causely mediator](https://docs.causely.ai/getting-started/how-causely-works/#mediation-layer), 
but it can be modified to work with other endpoints as well.

## Installation

You can install the OpenTelemetry Demo using helm:

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm install my-otel-demo open-telemetry/opentelemetry-demo -f values.yaml
```

After you have installed the demo, deploy Causely, following the instructions of the [Getting Started guide](https://docs.causely.ai/getting-started/quick-setup/).

Make sure that you enable the port forwarding for the frontend-proxy of the Demo to interact with the services (including the feature flag UI):

```shell
kubectl --namespace default port-forward svc/frontend-proxy 8080:8080
```

**Note**: If you use [minikube](https://minikube.sigs.k8s.io/docs/), make sure to run `minikube tunnel` in a separate terminal!

## Usage

To simulate incidents in the deployed demo application go to <http://localhost:8080/feature> and toggle one of the available [feature flags](https://opentelemetry.io/docs/demo/feature-flags/),

## License

This project is licensed under the Apache 2.0 License.

## Contributing

Contributions are welcome. Please submit pull requests or open issues for any changes or improvements.
