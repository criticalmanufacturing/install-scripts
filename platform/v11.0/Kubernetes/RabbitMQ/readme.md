This helmchart was created based of the documentation provided in https://artifacthub.io/packages/helm/bitnami/rabbitmq and 
https://github.com/bitnami/charts/blob/main/bitnami/rabbitmq/README.md. 

Before running the script please verify and edit the values in values.yaml. If you need more customization for your RabbitMQ deployment please check https://github.com/bitnami/charts/blob/main/bitnami/rabbitmq/values.yaml.

helm install <releaseName> --namespace <namespace> oci://registry-1.docker.io/bitnamicharts/rabbitmq -f values.yaml --version 14.6.6
