# OTel Demo for Causely

This project provides all the configurations needed to deploy the [OpenTelemetry Demo](https://opentelemetry.io/docs/demo/) without the out of the box observability stack (Prometheus, Jaeger, Grafana, OpenSearch)
and a custom OpenTelemetry collector configuration.

By default the configuration is for ingesting telemetry into the [Causely mediator](https://docs.causely.ai/getting-started/how-causely-works/#mediation-layer), but it can
be modified to work with other endpoints as well.

Additionally this project includes the python tool [`toggle-flags.py`](./chaos-scheduler/toggle-flags.py) to toggle feature flags of the OpenTelemetry Demo,
and another python tool [`chaos-scheduler.py`](./chaos-scheduler/chaos-scheduler.py) that will toggle them with a randomized schedule.

## Installation

You can install the OpenTelemetry Demo using helm:

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-chart
helm install my-otel-demo open-telemetry/opentelemetry-demo -f values.yaml
```

If you want to also deploy Causely in your cluster, you can follow the instructions of the [Causely Getting Started guide](https://docs.causely.ai/getting-started/quick-setup/), i.e.

```bash
export CAUSELY_TOKEN=${CAUSELY_TOKEN} # obtain the token from your Causely tenant.
export CAUSELY_VERSION=v1.0.83-0-g6559d4c064695c5b # replace with most recent version
export CLUSTER_NAME=minikube # replace with your cluster name
helm upgrade --version=${CAUSELY_VERSION} --install causely --create-namespace oci://us-docker.pkg.dev/public-causely/public/causely --namespace=causely --set global.cluster_name=${CLUSTER_NAME} --set mediator.gateway.token=${CAUSELY_TOKEN}
```

If you want to use a different observability backend, open [values.yaml](./values.yaml) and set your endpoint:

```yaml
exporters:
  otlp:
    endpoint: <URL_OF_YOUR_ENDPOINT>
```

To use the python tools, run the [setup.sh](./chaos-scheduler/setup.sh) from within the [chaos-scheduler](./chaos-scheduler/) directory:

```shell
cd chaos-scheduler
./setup.sh
```

Make sure that you enable the port forwarding for the frontend-proxy of the Demo to interact with the services (including the feature flag UI):

```shell
kubectl --namespace default port-forward svc/frontend-proxy 8080:8080
```

**Note**: If you use minikube, make sure to run `minikube tunnel` in a separate terminal!

## Usage

The deployed OpenTelemetry Demo comes with all the features except the disabled out of the box observability stack,
so you can follow the [documentation for the demo](https://opentelemetry.io/docs/demo/) to learn how you can interact with it.

To interact with the feature flags of the OpenTelemetry from the commandline you can use `toggle-flags.py` as follows:

- List available feature flags: `./toggle-flags.py list`
- Set a feature flag: `./toggle-flags.py <name> value`, for example `./toggle-flags.py adFailure on`
- To interact with the feature flag UI service on a different URL: `./toggle-flags.py adFailure on --base-url http://example.com:9090/feature/api`
- To get a list of all available commands and options: `./toggle-flags.py --help`

To run a randomized schedule which will toggle feature flags, you can use the `chaos-scheduler.py`. The scheduler expects an "interval" as argument.
Based on this interval the script will toggle one feature flag at a random point in time within each interval of that duration, for example if
you set an interval of 15 minutes by running `./chaos-scheduler.py 15min` you will see the following behavior:

- Between minute 0 and 15, feature flag `A` gets enabled and disabled before the interval ends
- Between minute 15 and 30, feature flag `B` gets enabled and disabled before the interval ends
- ...

The script also accepts `--dry-run` as parameter for testing, `--seed` to have reproducible schedules and `--base-url` to set a different URL for the feature flag UI:

```shell
$ python chaos-scheduler.py 30sec --dry-run --seed 42 --base-url http://example.com:9090/feature/api
[2025-07-03 11:13:43] 🚀 Starting Chaos Scheduler with interval: 30s
[2025-07-03 11:13:43] 🧪 Running in DRY-RUN mode - no actual changes will be made
[2025-07-03 11:13:43] 🎲 Using seed: 42 (for reproducible patterns)
[2025-07-03 11:13:43] 📅 Beginning interval #1 (duration: 30s)
[2025-07-03 11:13:43] ⏰ Next trigger scheduled in 20s (at 11:14:03)
[2025-07-03 11:14:03] 🎯 TRIGGER: Setting recommendationCacheFailure to on for 5s
[2025-07-03 11:14:03] 🧪 [DRY-RUN] Would run: ./toggle-flags.py recommendationCacheFailure on --base-url http://example.com:9090/feature/api
[2025-07-03 11:14:08] 🔄 REVERT: Setting recommendationCacheFailure back to off
[2025-07-03 11:14:08] 🧪 [DRY-RUN] Would run: ./toggle-flags.py recommendationCacheFailure off --base-url http://example.com:9090/feature/api
[2025-07-03 11:14:08] ⏸️  Waiting 4s until end of interval
[2025-07-03 11:14:12] 🏁 End of interval #1
```

## License

This project is licensed under the Apache 2.0 License.

## Contributing

Contributions are welcome. Please submit pull requests or open issues for any changes or improvements.
