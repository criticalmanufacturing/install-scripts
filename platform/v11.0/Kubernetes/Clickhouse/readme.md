# ClickHouse Helm Chart

This Helm chart deploys ClickHouse on Kubernetes. Follow the steps below to configure and deploy the chart.

## Configuration

Before deploying this Helm chart, ensure you replace the following placeholders in the `values.yaml` file:

- `<cluster suffix>`
- `<storage class for data>`
- `<storage class for logs>`
- `<default user password>`
- `<Secret name with kafka certificates>`

Additionally, increase the volume sizes if necessary.

## Deployment

To deploy the Helm chart, navigate to the Helm chart directory and run the following command (make sure to replace the placeholders first):

```sh
helm install <Release Name> --namespace <Namespace> --create-namespace .
```

## Example

```sh
helm install my-clickhouse --namespace clickhouse-namespace --create-namespace .
```

## Notes

- Ensure that your Kubernetes cluster has sufficient resources for the requested CPU and memory limits.
- Verify that the storage classes specified in `values.yaml` are available in your cluster.
