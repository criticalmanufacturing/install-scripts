This helmchart was created based of the documentation provided in https://artifacthub.io/packages/helm/bitnami/rabbitmq and 
https://github.com/bitnami/charts/blob/main/bitnami/rabbitmq/values.yaml. 

Before running the script please verify and edit the values in values.yaml.

helm install <releaseName> --namespace <namespace> oci://registry-1.docker.io/bitnamicharts/rabbitmq -f values.yaml
